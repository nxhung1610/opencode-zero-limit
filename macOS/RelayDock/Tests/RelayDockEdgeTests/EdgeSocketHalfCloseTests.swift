import Darwin
import Foundation
import Testing
@testable import RelayDockEdge

/// Upstream tunnels are Network.framework connections, so FIN propagation is
/// verified against a real loopback TCP listener — the descriptor backend
/// only covers accepted client sockets.
struct EdgeSocketHalfCloseTests {
    private func makeLoopbackListener() throws -> (fd: Int32, port: UInt16) {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw EdgeSocketError.connectFailed("listener socket failed")
        }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, Darwin.listen(fd, 1) == 0 else {
            let code = errno
            Darwin.close(fd)
            throw EdgeSocketError.connectFailed("listener bind failed (POSIX \(code))")
        }

        var local = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &local) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &length)
            }
        }
        guard named == 0 else {
            let code = errno
            Darwin.close(fd)
            throw EdgeSocketError.connectFailed("getsockname failed (POSIX \(code))")
        }
        return (fd, UInt16(bigEndian: local.sin_port))
    }

    @Test func networkSocketHalfCloseEndsOnlyTheWriteDirection() async throws {
        let listener = try makeLoopbackListener()
        defer { Darwin.close(listener.fd) }

        let server = Task.detached { () -> (request: Data, writeFailed: Bool) in
            let fd = Darwin.accept(listener.fd, nil, nil)
            guard fd >= 0 else { return (Data(), true) }
            defer { Darwin.close(fd) }
            var on: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))

            var request = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = Darwin.recv(fd, &buffer, buffer.count, 0)
                if count > 0 {
                    request.append(contentsOf: buffer[0..<count])
                    continue
                }
                if count == 0 { break }
                if errno == EINTR { continue }
                return (request, true)
            }

            let response = Data("response".utf8)
            let sent = response.withUnsafeBytes { bytes in
                Darwin.send(fd, bytes.baseAddress, bytes.count, 0)
            }
            return (request, sent != response.count)
        }

        let client = EdgeSocket(host: "127.0.0.1", port: listener.port)
        defer { client.cancel() }
        try await withEdgeTimeout(5, cancelling: client) {
            try await client.awaitReady()
        }
        try await client.send(Data("request".utf8))
        client.halfCloseWrite()

        var reply = Data()
        while true {
            let step = try await withEdgeTimeout(5, cancelling: client) {
                try await client.receiveSome()
            }
            reply.append(step.data)
            if step.isComplete { break }
        }
        #expect(String(decoding: reply, as: UTF8.self) == "response")

        let received = await server.value
        #expect(String(decoding: received.request, as: UTF8.self) == "request")
        #expect(!received.writeFailed)
    }
}
