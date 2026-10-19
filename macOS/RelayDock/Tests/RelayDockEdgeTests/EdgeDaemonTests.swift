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

    /// "Nothing resolved yet" must mean nothing, anywhere: a resolution Edge
    /// persisted in an earlier process (or one the app wrote) still counts
    /// after a restart — and Off mode, which never resolves a route, must
    /// still probe it instead of skipping every script entry.
    @Test func checkProbesAPersistedScriptResolutionWhenRoutingIsOff() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "relaydock-check-cache-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ProxyStore(configDirectory: directory)
        let script = "return 'http://127.0.0.1:9';"
        let imported = try store.addProxyScript(name: "Rotating", script: script)
        let entry = imported.proxies[0]
        defer { removeProxyScriptCacheSnapshot(for: entry.id) }
        _ = try store.setMode(.off, manualId: nil)
        let daemon = EdgeDaemon(
            config: EdgeConfigFile(port: 57_999),
            directory: directory,
            log: EdgeLog(url: directory.appending(path: "edge.log"))
        )

        // With no snapshot anywhere, the check is honestly deferred.
        let before = await daemon.runChecks(scope: .all)
        if case .deferred = before[entry.id] {} else {
            Issue.record("with nothing persisted there is nothing to probe")
        }

        try ScriptCacheFile(entries: [
            entry.id: .init(
                scriptHash: ScriptCacheFile.scriptHash(script),
                snapshot: #"{"url":"http://127.0.0.1:9"}"#
            ),
        ]).save(to: directory.appending(path: ScriptCacheFile.fileName))

        let outcomes = await daemon.runChecks(scope: .all)

        guard let outcome = outcomes[entry.id] else {
            Issue.record("an enabled script entry must be checked")
            return
        }
        if case .deferred(let reason, _) = outcome {
            Issue.record("a persisted resolution must be probed, not deferred: \(reason)")
        }
        if case .ok = outcome {
            Issue.record("the fixture's probe port is closed; the check must not pass")
        }
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
            config: EdgeConfigFile(port: 57_999),
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

    // MARK: - Direct fallback (opt-in)

    private func makeFallbackFixture() throws -> (directory: URL, store: ProxyStore, daemon: EdgeDaemon) {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "relaydock-fallback-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = ProxyStore(configDirectory: directory)
        let daemon = EdgeDaemon(
            config: EdgeConfigFile(port: 57_999),
            directory: directory,
            log: EdgeLog(url: directory.appending(path: "edge.log"))
        )
        return (directory, store, daemon)
    }

    /// The pool's opt-in direct fallback turns "nothing usable" from a
    /// refusal into a labeled direct answer; without the setting the same
    /// state stays fail-closed.
    @Test func directFallbackAnswersWhenNoUpstreamIsUsable() async throws {
        let (directory, store, daemon) = try makeFallbackFixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try store.setMode(.auto, manualId: nil)

        guard case .refuse = await daemon.decideRoute() else {
            Issue.record("an empty pool must refuse while direct fallback is off")
            return
        }

        _ = try store.setDirectFallback(true)
        #expect(await daemon.directFallbackEnabled())
        guard case .directFallback(let reason) = await daemon.decideRoute() else {
            Issue.record("direct fallback must answer when no upstream is usable")
            return
        }
        #expect(!reason.isEmpty)

        _ = try store.setDirectFallback(false)
        #expect(!(await daemon.directFallbackEnabled()))
        guard case .refuse = await daemon.decideRoute() else {
            Issue.record("turning the fallback off must restore fail-closed")
            return
        }
    }

    /// The setting is global consent, not a mode-specific patch: a manual
    /// selection gap falls back too.
    @Test func directFallbackCoversAManualSelectionGap() async throws {
        let (directory, store, daemon) = try makeFallbackFixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try store.save(ProxyState(mode: .manual, manualId: nil, directFallback: true))

        guard case .directFallback(let reason) = await daemon.decideRoute() else {
            Issue.record("a manual gap with the fallback on must answer direct")
            return
        }
        #expect(reason.contains("manual"))
    }

    /// One more tunnel served by fallback is visible in the status counters.
    @Test func directFallbackCountsSurfaceInStatus() async throws {
        let (directory, _, daemon) = try makeFallbackFixture()
        defer { try? FileManager.default.removeItem(at: directory) }

        await daemon.noteDirectFallback(reason: "no proxy in the pool is usable")
        await daemon.noteDirectFallback(reason: "the provider is cooling down")

        let status = await daemon.status()
        #expect(status.counters.directFallbacks == 2)
    }
}
