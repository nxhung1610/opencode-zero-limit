import Foundation
import Testing
import RelayDockCore
@testable import RelayDockEdge

struct EdgeRelayPolicyTests {
    @Test func upstreamDeathOutranksByteCounts() {
        #expect(EdgeRelayPolicy.verdict(end: .upstreamDied, requestSent: true, bytesUp: 0, bytesDown: 0, duration: 0.1) == .died)
        #expect(EdgeRelayPolicy.verdict(end: .upstreamDied, requestSent: true, bytesUp: 900, bytesDown: 900, duration: 90) == .died)
        #expect(EdgeRelayPolicy.verdict(end: .upstreamDied, requestSent: false, bytesUp: 0, bytesDown: 0, duration: 0) == .died)
    }

    @Test func longSilentTunnelsAreStalls() {
        // CONNECT path: request bytes flowed, nothing came back.
        #expect(EdgeRelayPolicy.verdict(end: .clientClosed, requestSent: false, bytesUp: 512, bytesDown: 0, duration: 31) == .stalled(duration: 31))
        // Forward path: the request head was sent before the relay started.
        #expect(EdgeRelayPolicy.verdict(end: .clientClosed, requestSent: true, bytesUp: 0, bytesDown: 0, duration: 45) == .stalled(duration: 45))
        // A silent clean close by the upstream with no response bytes counts too.
        #expect(EdgeRelayPolicy.verdict(end: .upstreamClosed, requestSent: true, bytesUp: 5, bytesDown: 0, duration: 31) == .stalled(duration: 31))
    }

    @Test func shortOrIdleOrAnsweredTunnelsAreClean() {
        // The client gave up before the stall window closed.
        #expect(EdgeRelayPolicy.verdict(end: .clientClosed, requestSent: true, bytesUp: 0, bytesDown: 0, duration: 29.9) == .clean)
        // An idle tunnel that never carried request bytes says nothing.
        #expect(EdgeRelayPolicy.verdict(end: .clientClosed, requestSent: false, bytesUp: 0, bytesDown: 0, duration: 600) == .clean)
        // One response byte is enough: TLS alone proves the endpoint lives.
        #expect(EdgeRelayPolicy.verdict(end: .clientClosed, requestSent: true, bytesUp: 10, bytesDown: 1, duration: 600) == .clean)
        #expect(EdgeRelayPolicy.verdict(end: .upstreamClosed, requestSent: true, bytesUp: 10, bytesDown: 2048, duration: 90) == .clean)
    }

    @Test func retryAfterHeadersUseWholeSeconds() {
        #expect(EdgeClientConnection.retryAfterHeaders(nil).isEmpty)
        #expect(EdgeClientConnection.retryAfterHeaders(0).isEmpty)
        #expect(EdgeClientConnection.retryAfterHeaders(-5).isEmpty)
        #expect(EdgeClientConnection.retryAfterHeaders(0.2) == ["Retry-After: 1"])
        #expect(EdgeClientConnection.retryAfterHeaders(25) == ["Retry-After: 25"])
        #expect(EdgeClientConnection.retryAfterHeaders(25.3) == ["Retry-After: 26"])
    }

    @Test func countersDecodeToleratesOlderEdgeBinaries() throws {
        let old = #"{"resolutions":1,"switches":2,"dialFailures":3,"tunnelsTotal":4,"tunnelsActive":5}"#
        let decoded = try JSONDecoder().decode(EdgeStatusResponse.Counters.self, from: Data(old.utf8))
        #expect(decoded.streamFailures == 0)
        #expect(decoded.directFallbacks == 0)
        #expect(decoded.resolutions == 1)
        #expect(decoded.tunnelsActive == 5)

        let current = #"{"resolutions":1,"switches":2,"dialFailures":3,"streamFailures":9,"directFallbacks":4,"tunnelsTotal":4,"tunnelsActive":5}"#
        let decodedCurrent = try JSONDecoder().decode(EdgeStatusResponse.Counters.self, from: Data(current.utf8))
        #expect(decodedCurrent.streamFailures == 9)
        #expect(decodedCurrent.directFallbacks == 4)
    }

    /// The fallback label is the honesty contract of the opt-in fallback:
    /// status consumers rely on this exact string to separate proxied
    /// tunnels from direct ones.
    @Test func directFallbackLabelIsStable() {
        #expect(EdgeClientConnection.directFallbackLabel == "direct (fallback)")
    }

    @Test func tunnelFailuresCountAndRecordEvenWithoutState() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("relaydock-edge-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let daemon = EdgeDaemon(
            config: EdgeConfigFile(port: 57211, token: "test-token"),
            directory: directory,
            log: EdgeLog(url: directory.appendingPathComponent("edge.log"))
        )
        await daemon.noteTunnelFailure(entryID: "px_missing", failure: .died)
        await daemon.noteTunnelFailure(entryID: "px_missing", failure: .stalled(duration: 42))
        let status = await daemon.status()
        #expect(status.counters.streamFailures == 2)
        #expect(status.lastErrors.contains { $0.contains("tunnel died mid-stream") })
        #expect(status.lastErrors.contains { $0.contains("zero-byte stall (42s)") })
        let retryAfter = await daemon.refusalRetryAfter()
        #expect(retryAfter == nil)
    }
}
