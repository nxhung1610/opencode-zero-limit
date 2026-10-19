import Foundation
import RelayDockCore
import Testing
@testable import RelayDockEdge

struct EdgeDaemonTests {
    @Test func readsExpiryFromScriptSnapshots() {
        let now = 1_000_000.0
        #expect(EdgeDaemon.snapshotExpiry(snapshot: #"{"expiresAt": 1777000000000}"#, now: now) == 1_777_000_000)
        #expect(EdgeDaemon.snapshotExpiry(snapshot: #"{"expires_at": 1000500}"#, now: now) == 1_000_500)
        #expect(EdgeDaemon.snapshotExpiry(snapshot: #"{"expiry": "1000600"}"#, now: now) == 1_000_600)
    }

    @Test func ignoresMissingStaleOrImplausibleExpiries() {
        let now = 1_000_000.0
        #expect(EdgeDaemon.snapshotExpiry(snapshot: nil, now: now) == nil)
        #expect(EdgeDaemon.snapshotExpiry(snapshot: "not json", now: now) == nil)
        #expect(EdgeDaemon.snapshotExpiry(snapshot: #"{"other": 1}"#, now: now) == nil)
        #expect(EdgeDaemon.snapshotExpiry(snapshot: #"{"expiresAt": 999000}"#, now: now) == nil)
    }

    /// A check probes the URL an entry is currently serving — live upstream,
    /// then a pinned upstream, then its script cache — and never runs the
    /// script, so Test All cannot rotate the exit or hit a provider cooldown.
    @Test func checkProbesPreferLiveAndPinnedUpstreamsOverTheScriptCache() {
        func upstream(_ id: String, _ url: String) -> EdgeUpstream {
            EdgeUpstream(
                entryID: id,
                label: id,
                url: url,
                source: "script",
                resolvedAt: 0,
                expiresAt: nil,
                refreshAt: nil,
                strikes: 0
            )
        }
        let live = upstream("live", "http://live.example:1")
        let pinned = upstream("pinned", "http://pinned.example:2")
        #expect(EdgeDaemon.resolvedURL(entryID: "live", upstream: live, pinned: nil, cacheURL: "http://cached.example:3") == "http://live.example:1")
        #expect(EdgeDaemon.resolvedURL(entryID: "pinned", upstream: live, pinned: pinned, cacheURL: "http://cached.example:3") == "http://pinned.example:2")
        #expect(EdgeDaemon.resolvedURL(entryID: "idle", upstream: live, pinned: nil, cacheURL: "http://cached.example:3") == "http://cached.example:3")
        #expect(EdgeDaemon.resolvedURL(entryID: "idle", upstream: nil, pinned: nil, cacheURL: nil) == nil)
    }

    /// A direct tunnel (its relay call passes `label: nil`) must not inherit
    /// the last resolved upstream's label; an upstream tunnel keeps exactly
    /// the label it dialed with.
    @Test func directTunnelsDoNotInheritAStaleUpstreamLabel() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "relaydock-labels-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ProxyStore(configDirectory: directory)
        let daemon = EdgeDaemon(
            config: EdgeConfigFile(port: 57_999, token: "test"),
            directory: directory,
            log: EdgeLog(url: directory.appending(path: "edge.log"))
        )

        _ = try store.importProxies("http://proxy-a.example:8080")
        _ = try store.setMode(.auto, manualId: nil)
        await daemon.warmup()

        let staleLabel = await daemon.status().upstream?.label
        #expect(staleLabel != nil, "fixture needs a resolved upstream for the regression to be observable")

        await daemon.registerTunnel(clientPort: 40_001, edgePort: 57_999, label: nil)
        await daemon.registerTunnel(clientPort: 40_002, edgePort: 57_999, label: "proxy-a.example:8080")

        let tunnels = await daemon.status().tunnels
        #expect(tunnels.first { $0.clientPort == 40_001 }?.label == nil)
        #expect(tunnels.first { $0.clientPort == 40_002 }?.label == "proxy-a.example:8080")
    }
}
