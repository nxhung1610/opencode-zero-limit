import Darwin
import Foundation
import Testing
@testable import RelayDockEdge

/// The descriptor backend of EdgeSocket (P3 socket activation + the accept
/// loop): the same async surface, blocking POSIX I/O underneath.
struct EdgeSocketFDTests {
    private func makePair() throws -> (EdgeSocket, EdgeSocket) {
        var pair: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else {
            throw EdgeSocketError.connectFailed("socketpair failed")
        }
        return (
            EdgeSocket(fd: pair[0], peerPort: 4001, label: "fd-a"),
            EdgeSocket(fd: pair[1], peerPort: 4002, label: "fd-b")
        )
    }

    @Test func descriptorSocketRoundTripsBytes() async throws {
        let (a, b) = try makePair()
        defer {
            a.cancel()
            b.cancel()
        }
        try await a.send(Data("hello relaydock".utf8))
        let (data, complete) = try await b.receiveSome()
        #expect(!complete)
        #expect(String(data: data, encoding: .utf8) == "hello relaydock")
        #expect(a.remotePort == 4001)
        #expect(b.remotePort == 4002)
        #expect(a.isReadyForReuse)
    }

    @Test func descriptorSocketReportsCleanEOF() async throws {
        let (a, b) = try makePair()
        defer { b.cancel() }
        try await a.send(Data("bye".utf8))
        a.cancel()
        let (data, complete) = try await b.receiveSome()
        #expect(String(data: data, encoding: .utf8) == "bye")
        #expect(!complete)
        let (tail, ended) = try await b.receiveSome()
        #expect(ended)
        #expect(tail.isEmpty)
    }

    @Test func cancelWakesABlockedRead() async throws {
        let (a, b) = try makePair()
        defer { b.cancel() }
        async let pending = b.receiveSome()
        try await Task.sleep(nanoseconds: 100_000_000)
        a.cancel()
        let (data, complete) = try await pending
        #expect(data.isEmpty)
        #expect(complete)
    }
}
