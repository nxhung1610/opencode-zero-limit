import Darwin
import Foundation
import Testing
import RelayDockCore
@testable import RelayDockEdge

/// End-to-end relay behavior over loopback TCP pairs: the client side is the
/// descriptor backend Edge accepts, the upstream side stands in for a dialed
/// tunnel. TCP (not socketpair) matches the production shutdown semantics —
/// `shutdown(SHUT_RDWR)` after the peer half-closes delivers EOF.
struct EdgeRelayTests {
    private func makeFixture() throws -> (directory: URL, daemon: EdgeDaemon) {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "relaydock-relay-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let daemon = EdgeDaemon(
            config: EdgeConfigFile(port: 57_999),
            directory: directory,
            log: EdgeLog(url: directory.appending(path: "edge.log"))
        )
        return (directory, daemon)
    }

    /// One connected loopback pair: the first socket is the peer (test side),
    /// the second is the endpoint Edge owns.
    private func makeTCPPair() throws -> (EdgeSocket, EdgeSocket) {
        let listener = socket(AF_INET, SOCK_STREAM, 0)
        guard listener >= 0 else {
            throw EdgeSocketError.connectFailed("listener socket failed")
        }
        defer { Darwin.close(listener) }
        var on: Int32 = 1
        setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, Darwin.listen(listener, 1) == 0 else {
            throw EdgeSocketError.connectFailed("listener bind failed (POSIX \(errno))")
        }

        var local = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &local) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(listener, $0, &length)
            }
        }
        guard named == 0 else {
            throw EdgeSocketError.connectFailed("getsockname failed (POSIX \(errno))")
        }

        let peerFD = socket(AF_INET, SOCK_STREAM, 0)
        guard peerFD >= 0 else {
            throw EdgeSocketError.connectFailed("peer socket failed")
        }
        let connected = withUnsafePointer(to: &local) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(peerFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else {
            let code = errno
            Darwin.close(peerFD)
            throw EdgeSocketError.connectFailed("connect failed (POSIX \(code))")
        }
        let edgeFD = Darwin.accept(listener, nil, nil)
        guard edgeFD >= 0 else {
            Darwin.close(peerFD)
            throw EdgeSocketError.connectFailed("accept failed (POSIX \(errno))")
        }
        return (EdgeSocket(fd: peerFD), EdgeSocket(fd: edgeFD))
    }

    private func readToEOF(
        _ socket: EdgeSocket,
        within seconds: TimeInterval = 5
    ) async throws -> Data {
        try await withEdgeTimeout(seconds, cancelling: socket) {
            var data = Data()
            while true {
                let step = try await socket.receiveSome()
                data.append(step.data)
                if step.isComplete { return data }
            }
        }
    }

    private func makeConnection(
        socket: EdgeSocket,
        daemon: EdgeDaemon,
        directory: URL
    ) -> EdgeClientConnection {
        EdgeClientConnection(
            socket: socket,
            peerPort: nil,
            daemon: daemon,
            edgePort: 58_000,
            log: EdgeLog(url: directory.appending(path: "edge.log"))
        )
    }

    /// A client that half-closes after its request still gets the whole
    /// response. Cancelling the tunnel on client EOF truncated the response
    /// and was the reason half-close support was added.
    @Test func clientHalfCloseStillDeliversTheFullResponse() async throws {
        let (directory, daemon) = try makeFixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (client, edgeClient) = try makeTCPPair()
        let (upstream, edgeUpstream) = try makeTCPPair()
        defer {
            client.cancel()
            upstream.cancel()
        }

        let connection = makeConnection(socket: edgeClient, daemon: daemon, directory: directory)
        let relay = Task {
            try await connection.relay(
                to: EdgeUpstreamTunnel(socket: edgeUpstream, initialData: Data()),
                clientPrelude: Data(),
                upstreamEntryID: nil,
                label: nil
            )
        }

        let request = Data("GET / HTTP/1.1\r\nHost: example.test\r\n\r\n".utf8)
        try await client.send(request)
        client.halfCloseWrite()

        // The upstream sees the request and then the forwarded FIN.
        let upstreamReceived = try await readToEOF(upstream)
        #expect(upstreamReceived == request)

        let response = Data(
            "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nOK".utf8
        )
        try await upstream.send(response)
        upstream.halfCloseWrite()

        let clientReadStarted = Date()
        let clientReceived = try await readToEOF(client)
        #expect(clientReceived == response)
        // A missing EOF must fail here, not be masked by readToEOF's own
        // timeout cancelling the socket.
        #expect(Date().timeIntervalSince(clientReadStarted) < 1)
        try await withEdgeTimeout(5, cancelling: edgeUpstream) { try await relay.value }
    }

    /// A silent upstream must not leak the relay after the client half-closes:
    /// the first-byte watchdog ends it and closes the client side.
    @Test func aSilentUpstreamAfterHalfCloseEndsTheRelay() async throws {
        let (directory, daemon) = try makeFixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (client, edgeClient) = try makeTCPPair()
        let (upstream, edgeUpstream) = try makeTCPPair()
        defer {
            client.cancel()
            upstream.cancel()
        }

        let connection = makeConnection(socket: edgeClient, daemon: daemon, directory: directory)
        let relay = Task {
            try await connection.relay(
                to: EdgeUpstreamTunnel(socket: edgeUpstream, initialData: Data()),
                clientPrelude: Data(),
                upstreamEntryID: nil,
                label: nil,
                halfCloseFirstByteTimeout: 0.2
            )
        }

        let started = Date()
        let request = Data("GET / HTTP/1.1\r\nHost: example.test\r\n\r\n".utf8)
        try await client.send(request)
        client.halfCloseWrite()
        let upstreamReceived = try await readToEOF(upstream)
        #expect(upstreamReceived == request)

        // The upstream stays open and silent; the watchdog is the only exit.
        // Cancelling the tunnel on timeout keeps a regression from hanging
        // the test run; the elapsed bound proves the watchdog did the work.
        let relayStarted = Date()
        try await withEdgeTimeout(3, cancelling: edgeUpstream) { try await relay.value }
        #expect(Date().timeIntervalSince(relayStarted) < 1)
        #expect(Date().timeIntervalSince(started) >= 0.1)

        let eofStarted = Date()
        let (tail, ended) = try await withEdgeTimeout(5, cancelling: client) {
            try await client.receiveSome()
        }
        #expect(Date().timeIntervalSince(eofStarted) < 1)
        #expect(tail.isEmpty)
        #expect(ended)
    }

    /// A client that already waited the full stall window and then gives up
    /// must not grant the silent upstream a second watchdog window.
    @Test func aSilentUpstreamThatOutlivedTheStallWindowEndsImmediately() async throws {
        let (directory, daemon) = try makeFixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (client, edgeClient) = try makeTCPPair()
        let (upstream, edgeUpstream) = try makeTCPPair()
        defer {
            client.cancel()
            upstream.cancel()
        }

        let connection = makeConnection(socket: edgeClient, daemon: daemon, directory: directory)
        let relay = Task {
            try await connection.relay(
                to: EdgeUpstreamTunnel(socket: edgeUpstream, initialData: Data()),
                clientPrelude: Data(),
                upstreamEntryID: nil,
                label: nil,
                halfCloseFirstByteTimeout: 0.2
            )
        }

        let request = Data("GET / HTTP/1.1\r\nHost: example.test\r\n\r\n".utf8)
        try await client.send(request)
        // Outlive the stall window while the upstream stays silent.
        try await Task.sleep(nanoseconds: 250_000_000)
        let halfClosedAt = Date()
        client.halfCloseWrite()

        try await withEdgeTimeout(2, cancelling: edgeUpstream) { try await relay.value }
        #expect(Date().timeIntervalSince(halfClosedAt) < 0.1)
    }
}
