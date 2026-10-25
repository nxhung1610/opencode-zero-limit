import Foundation
import RelayDockCore
import Testing
@testable import RelayDockEdge

struct EdgeDaemonTests {
    @Test func freeUsageLimitReportUsesFreshSameProcessTunnelAndEdgePort() {
        let now = 2_000.0
        func tunnel(
            pid: Int32?,
            port: UInt16 = 57_211,
            entryID: String? = "px_a",
            startedAt: Double,
            endedAt: Double? = nil,
            active: Bool
        ) -> EdgeDaemon.TunnelRecord {
            EdgeDaemon.TunnelRecord(
                clientPort: 40_000,
                edgePort: port,
                entryID: entryID,
                label: entryID,
                peerPid: pid,
                peerName: "opencode",
                startedAt: startedAt,
                endedAt: endedAt,
                bytesUp: 0,
                bytesDown: 0,
                active: active
            )
        }
        let match = EdgeDaemon.matchingTunnel(
            peerPID: 123,
            edgePort: 57_211,
            active: [tunnel(pid: 123, startedAt: now - 5, active: true)],
            recent: [
                tunnel(pid: 123, startedAt: now - 10, endedAt: now - 1, active: false),
                tunnel(pid: 999, startedAt: now - 1, endedAt: now - 1, active: false),
                tunnel(pid: 123, port: 57_212, startedAt: now, endedAt: now, active: false),
                tunnel(pid: 123, startedAt: now - 200, endedAt: now - 121, active: false),
            ],
            now: now
        )

        #expect(match?.entryID == "px_a")
        #expect(match?.startedAt == now - 5)
        #expect(EdgeDaemon.validFreeUsageCooldown(34_033_000))
        #expect(!EdgeDaemon.validFreeUsageCooldown(999))
        #expect(!EdgeDaemon.validFreeUsageCooldown(604_800_001))
    }

    @Test func freeUsageLimitCooldownPersistsAndAutoSkipsThatProxy() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "relaydock-free-limit-route-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ProxyStore(configDirectory: directory)
        let imported = try store.importProxies("http://first.example:8080\nhttp://second.example:8080")
        _ = try store.setMode(.auto, manualId: nil)
        let daemon = EdgeDaemon(
            config: EdgeConfigFile(port: 57_999),
            directory: directory,
            log: EdgeLog(url: directory.appending(path: "edge.log"))
        )
        let now = Date().timeIntervalSince1970

        let result = await daemon.persistFreeUsageLimit(
            entryID: imported.proxies[0].id,
            retryAfterMs: 3_600_000,
            now: now
        )
        let route = await daemon.decideRoute()
        var refreshed = try store.loadWithFreeUsageLimits(now: now)

        #expect(result == .flagged(entryID: imported.proxies[0].id, retryAt: now + 3_600))
        #expect(refreshed.proxies[0].isFreeUsageLimited(at: now))
        guard case .upstream(let selected) = route else {
            Issue.record("Auto should continue through an available proxy")
            return
        }
        #expect(selected.entryID == imported.proxies[1].id)

        _ = await daemon.persistFreeUsageLimit(
            entryID: imported.proxies[1].id,
            retryAfterMs: 3_600_000,
            now: now
        )
        refreshed = try store.loadWithFreeUsageLimits(now: now)
        let exhaustedRoute = await daemon.decideRoute()
        #expect(refreshed.autoEligibleProxies(at: now).isEmpty)
        guard case .refuse(_, let retryAt) = exhaustedRoute else {
            Issue.record("Auto must refuse while every proxy is waiting for reset")
            return
        }
        #expect(retryAt == now + 3_600)
    }

    @Test func explicitFreeUsageReportsOnlyAcceptAnOpenCodeReporter() {
        #expect(EdgeDaemon.isOpenCodeProcessName("opencode"))
        #expect(!EdgeDaemon.isOpenCodeProcessName("curl"))
        #expect(!EdgeDaemon.isOpenCodeProcessName("node"))
    }

    @Test func manualAndPinnedRoutesRefuseAProxyDuringItsFreeLimitCooldown() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "relaydock-free-limit-manual-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ProxyStore(configDirectory: directory)
        let imported = try store.importProxies("http://first.example:8080")
        let entry = imported.proxies[0]
        _ = try store.setMode(.manual, manualId: entry.id)
        let daemon = EdgeDaemon(
            config: EdgeConfigFile(port: 57_999),
            directory: directory,
            log: EdgeLog(url: directory.appending(path: "edge.log"))
        )
        let now = Date().timeIntervalSince1970
        _ = await daemon.persistFreeUsageLimit(entryID: entry.id, retryAfterMs: 3_600_000, now: now)

        let manual = await daemon.decideRoute()
        let pinned = await daemon.decideRoute(pinning: entry.id)

        for route in [manual, pinned] {
            guard case .refuse(_, let retryAt) = route else {
                Issue.record("manual and pinned routing must not reuse a rate-limited proxy")
                return
            }
            #expect(retryAt == now + 3_600)
        }
    }

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

        let imported = try store.importProxies("http://proxy-a.example:8080")
        let entry = imported.proxies[0]
        _ = try store.setMode(.auto, manualId: nil)
        await daemon.warmup()

        let staleLabel = await daemon.status().upstream?.label
        #expect(staleLabel != nil, "fixture needs a resolved upstream for the regression to be observable")

        await daemon.registerTunnel(clientPort: 40_001, edgePort: 57_999, entryID: nil, label: nil)
        await daemon.registerTunnel(clientPort: 40_002, edgePort: 57_999, entryID: entry.id, label: "proxy-a.example:8080")

        let tunnels = await daemon.status().tunnels
        #expect(tunnels.first { $0.clientPort == 40_001 }?.label == nil)
        #expect(tunnels.first { $0.clientPort == 40_002 }?.label == "proxy-a.example:8080")
    }

    @Test func autoRoutesRoundRobinAcrossEligibleProxiesPerNewTunnel() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "relaydock-auto-rotation-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ProxyStore(configDirectory: directory)
        let imported = try store.importProxies(
            "http://proxy-a.example:8080\nhttp://proxy-b.example:8080\nhttp://proxy-c.example:8080"
        )
        _ = try store.setMode(.auto, manualId: nil)
        let daemon = EdgeDaemon(
            config: EdgeConfigFile(port: 57_999),
            directory: directory,
            log: EdgeLog(url: directory.appending(path: "edge.log"))
        )
        await daemon.warmup()

        var selected: [String] = []
        for _ in 0..<7 {
            guard case .upstream(let upstream) = await daemon.decideRoute() else {
                Issue.record("Auto must select an eligible proxy for each new tunnel")
                return
            }
            selected.append(upstream.entryID)
        }
        let ids = imported.proxies.map(\.id)
        #expect(selected == [ids[0], ids[1], ids[2], ids[0], ids[1], ids[2], ids[0]])
    }

    @Test func autoDialFailureRetriesThroughAnotherEligibleProxy() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "relaydock-auto-retry-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ProxyStore(configDirectory: directory)
        let imported = try store.importProxies(
            "http://proxy-a.example:8080\nhttp://proxy-b.example:8080"
        )
        _ = try store.setMode(.auto, manualId: nil)
        let daemon = EdgeDaemon(
            config: EdgeConfigFile(port: 57_999),
            directory: directory,
            log: EdgeLog(url: directory.appending(path: "edge.log"))
        )
        await daemon.warmup()

        guard case .upstream(let first) = await daemon.decideRoute(),
              let replacement = await daemon.noteDialFailure(for: first, reResolve: true) else {
            Issue.record("a dial failure should retry through another eligible proxy")
            return
        }
        #expect(replacement.entryID != first.entryID)
        #expect(imported.proxies.contains { $0.id == replacement.entryID })
    }

    @Test func autoDialFailureReResolvesASingleCustomEntry() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "relaydock-auto-single-script-retry-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ProxyStore(configDirectory: directory)
        let imported = try store.addProxyScript(name: "Rotating", script: "return 'http://proxy.example:8080';")
        let entry = imported.proxies[0]
        defer { removeProxyScriptCacheSnapshot(for: entry.id) }
        _ = try store.setMode(.auto, manualId: nil)
        let daemon = EdgeDaemon(
            config: EdgeConfigFile(port: 57_999),
            directory: directory,
            log: EdgeLog(url: directory.appending(path: "edge.log"))
        )
        await daemon.warmup()

        guard case .upstream(let first) = await daemon.decideRoute(),
              let replacement = await daemon.noteDialFailure(for: first, reResolve: true) else {
            Issue.record("a single custom entry should get one fresh script resolution after a dial failure")
            return
        }

        #expect(replacement.entryID == entry.id)
        #expect(replacement.source == "script")
        #expect(replacement.url == first.url)
        #expect(await daemon.status().counters.resolutions >= 2)
    }

    @Test func manualModeKeepsItsSelectedProxy() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "relaydock-manual-route-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ProxyStore(configDirectory: directory)
        let imported = try store.importProxies(
            "http://proxy-a.example:8080\nhttp://proxy-b.example:8080"
        )
        let selectedID = imported.proxies[1].id
        _ = try store.setMode(.manual, manualId: selectedID)
        let daemon = EdgeDaemon(
            config: EdgeConfigFile(port: 57_999),
            directory: directory,
            log: EdgeLog(url: directory.appending(path: "edge.log"))
        )

        for _ in 0..<3 {
            guard case .upstream(let upstream) = await daemon.decideRoute() else {
                Issue.record("Manual must keep selecting its configured proxy")
                return
            }
            #expect(upstream.entryID == selectedID)
        }
    }

    // MARK: - Manual fail-closed

    private func makeManualFixture() throws -> (directory: URL, store: ProxyStore, daemon: EdgeDaemon) {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "relaydock-manual-fail-closed-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = ProxyStore(configDirectory: directory)
        let daemon = EdgeDaemon(
            config: EdgeConfigFile(port: 57_999),
            directory: directory,
            log: EdgeLog(url: directory.appending(path: "edge.log"))
        )
        return (directory, store, daemon)
    }

    @Test func manualSelectionDisabledRefusesInsteadOfServingTheCachedUpstream() async throws {
        let (directory, store, daemon) = try makeManualFixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let imported = try store.importProxies("http://proxy-a.example:8080")
        let entry = imported.proxies[0]
        _ = try store.setMode(.manual, manualId: entry.id)

        guard case .upstream(let cached) = await daemon.decideRoute(), cached.entryID == entry.id else {
            Issue.record("the selected entry should resolve first")
            return
        }

        _ = try store.setEnabled(entry.id, enabled: false)
        guard case .refuse(let reason, _) = await daemon.decideRoute() else {
            Issue.record("a disabled manual selection must refuse instead of serving its cached endpoint")
            return
        }
        #expect(reason.contains("disabled"))
    }

    @Test func manualSelectionRemovalRefusesInsteadOfServingTheCachedUpstream() async throws {
        let (directory, store, daemon) = try makeManualFixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let imported = try store.importProxies("http://proxy-a.example:8080")
        let entry = imported.proxies[0]
        _ = try store.setMode(.manual, manualId: entry.id)

        guard case .upstream = await daemon.decideRoute() else {
            Issue.record("the selected entry should resolve first")
            return
        }

        _ = try store.remove(entry.id)
        guard case .refuse(let reason, _) = await daemon.decideRoute() else {
            Issue.record("a removed manual selection must refuse instead of serving its cached endpoint")
            return
        }
        #expect(reason.contains("No proxy is selected"))
    }

    @Test func switchingManualSelectionDropsTheCachedUpstream() async throws {
        let (directory, store, daemon) = try makeManualFixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let imported = try store.importProxies(
            "http://proxy-a.example:8080\nhttp://proxy-b.example:8080"
        )
        _ = try store.setMode(.manual, manualId: imported.proxies[0].id)
        guard case .upstream(let first) = await daemon.decideRoute() else {
            Issue.record("the first selection should resolve")
            return
        }
        #expect(first.entryID == imported.proxies[0].id)

        _ = try store.setMode(.manual, manualId: imported.proxies[1].id)
        guard case .upstream(let second) = await daemon.decideRoute() else {
            Issue.record("the new selection should resolve")
            return
        }
        #expect(second.entryID == imported.proxies[1].id)
    }

    @Test func manualSwitchAfterACooldownUsesTheNewSelectionImmediately() async throws {
        let (directory, store, daemon) = try makeManualFixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let scripted = try store.addProxyScript(
            name: "Cooling down",
            script: "throw new Error('Còn 15s mới có thể đổi proxy');"
        )
        let cooling = scripted.proxies[0]
        let imported = try store.importProxies("http://proxy-b.example:8080")
        let healthy = try #require(imported.proxies.first { $0.url == "http://proxy-b.example:8080" })
        _ = try store.setMode(.manual, manualId: cooling.id)

        guard case .refuse(_, let retryAt) = await daemon.decideRoute() else {
            Issue.record("a failing script must refuse while its provider cools down")
            return
        }
        #expect(retryAt != nil)

        _ = try store.setMode(.manual, manualId: healthy.id)
        guard case .upstream(let selected) = await daemon.decideRoute() else {
            Issue.record("a new manual selection must not inherit the previous entry's cooldown")
            return
        }
        #expect(selected.entryID == healthy.id)
    }

    /// A resolve started for one manual selection must not be served to a
    /// request that has already switched to another selection. Both the joiner
    /// and the creator discard the stale outcome; the next request resolves the
    /// new entry from scratch.
    @Test func switchingSelectionWhileAScriptResolvesNeverServesTheOldEndpoint() async throws {
        let (directory, store, daemon) = try makeManualFixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let added = try store.addProxyScript(name: "Slow", script: """
        await new Promise(function (resolve) { setTimeout(resolve, 1500); });
        return 'http://slow.example:8080';
        """)
        let slowEntry = added.proxies[0]
        defer { removeProxyScriptCacheSnapshot(for: slowEntry.id) }
        let imported = try store.importProxies("http://fast.example:9090")
        let fastEntry = try #require(imported.proxies.first { $0.url == "http://fast.example:9090" })
        _ = try store.setMode(.manual, manualId: slowEntry.id)

        let first = Task { await daemon.decideRoute() }
        // The script keeps the detached resolve busy while the selection moves.
        try await Task.sleep(nanoseconds: 300_000_000)
        _ = try store.setMode(.manual, manualId: fastEntry.id)

        guard case .refuse = await daemon.decideRoute() else {
            Issue.record("the joining request must discard a resolve started for the old selection")
            return
        }
        if case .upstream(let stale) = await first.value {
            Issue.record("the creator must not serve the old selection's endpoint \(stale.url)")
        }
        #expect(await daemon.status().upstream == nil, "a stale resolve must not be applied")

        guard case .upstream(let fresh) = await daemon.decideRoute() else {
            Issue.record("the next request should resolve the new selection")
            return
        }
        #expect(fresh.entryID == fastEntry.id)
        #expect(fresh.url == "http://fast.example:9090")
    }

    /// Editing the selected script while its old version is resolving must not
    /// leak the old endpoint into the edited entry's route.
    @Test func editingTheSelectedScriptWhileResolvingNeverServesTheOldEndpoint() async throws {
        let (directory, store, daemon) = try makeManualFixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let added = try store.addProxyScript(name: "Rotating", script: """
        await new Promise(function (resolve) { setTimeout(resolve, 1500); });
        return 'http://old.example:8080';
        """)
        let entry = added.proxies[0]
        defer { removeProxyScriptCacheSnapshot(for: entry.id) }
        _ = try store.setMode(.manual, manualId: entry.id)

        let first = Task { await daemon.decideRoute() }
        try await Task.sleep(nanoseconds: 300_000_000)
        _ = try store.updateProxyScript(
            id: entry.id,
            name: "Rotating",
            script: "return 'http://new.example:8080';"
        )

        guard case .refuse = await daemon.decideRoute() else {
            Issue.record("the joining request must discard a resolve started for the old script")
            return
        }
        if case .upstream(let stale) = await first.value {
            Issue.record("the creator must not serve the edited script's old endpoint \(stale.url)")
        }
        #expect(await daemon.status().upstream == nil, "an edited script's old resolve must not be applied")

        guard case .upstream(let fresh) = await daemon.decideRoute() else {
            Issue.record("the edited script should resolve on the next request")
            return
        }
        #expect(fresh.entryID == entry.id)
        #expect(fresh.url == "http://new.example:8080")
    }

    @Test func manualTransientFailureKeepsTheSameEntry() async throws {
        let (directory, store, daemon) = try makeManualFixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = """
        if (cache.attempts) { throw new Error("Còn 9s mới có thể đổi proxy"); }
        cache.attempts = 1;
        cache.url = "http://proxy-a.example:8080";
        cache.expiresAt = Date.now() + 8000;
        return cache.url;
        """
        let added = try store.addProxyScript(name: "Transient", script: script)
        let entry = added.proxies[0]
        defer { removeProxyScriptCacheSnapshot(for: entry.id) }
        _ = try store.setMode(.manual, manualId: entry.id)

        guard case .upstream(let first) = await daemon.decideRoute() else {
            Issue.record("the script should resolve on its first run")
            return
        }
        #expect(first.url == "http://proxy-a.example:8080")
        #expect(first.refreshAt != nil)
        #expect((first.refreshAt ?? .infinity) < Date().timeIntervalSince1970)

        // The snapshot's lifetime puts `refreshAt` in the past, so this
        // decision re-resolves; the script then reports a provider cooldown.
        guard case .upstream(let second) = await daemon.decideRoute() else {
            Issue.record("a refresh failure on the same entry must keep serving the cached endpoint")
            return
        }
        #expect(second.entryID == entry.id)
        #expect(second.url == first.url)
        let status = await daemon.status()
        #expect(status.throttleRetryAt != nil)
        #expect(status.lastErrors.contains { $0.hasPrefix("deferred:") })

        guard case .upstream(let third) = await daemon.decideRoute() else {
            Issue.record("the cached endpoint must survive the provider cooldown window")
            return
        }
        #expect(third.entryID == entry.id)
    }

    @Test func manualFailureWithDirectFallbackUsesFallbackNotTheCachedUpstream() async throws {
        let (directory, store, daemon) = try makeManualFixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let imported = try store.importProxies("http://proxy-a.example:8080")
        let entry = imported.proxies[0]
        _ = try store.setMode(.manual, manualId: entry.id)
        _ = try store.setDirectFallback(true)

        guard case .upstream = await daemon.decideRoute() else {
            Issue.record("the selected entry should resolve first")
            return
        }

        _ = try store.setEnabled(entry.id, enabled: false)
        guard case .directFallback(let reason) = await daemon.decideRoute() else {
            Issue.record("the opt-in fallback must dial direct rather than reuse the disabled entry")
            return
        }
        #expect(reason.contains("disabled"))
    }

    @Test func editingTheActiveManualScriptClearsItsCooldown() async throws {
        let (directory, store, daemon) = try makeManualFixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let added = try store.addProxyScript(
            name: "Before edit",
            script: "throw new Error('Còn 15s mới có thể đổi proxy');"
        )
        let entry = added.proxies[0]
        _ = try store.setMode(.manual, manualId: entry.id)

        guard case .refuse = await daemon.decideRoute() else {
            Issue.record("the failing script should refuse")
            return
        }

        _ = try store.updateProxyScript(
            id: entry.id,
            name: "After edit",
            script: "return 'http://proxy-a.example:8080';"
        )
        guard case .upstream(let selected) = await daemon.decideRoute() else {
            Issue.record("an edited script must not stay blocked by the old script's cooldown")
            return
        }
        #expect(selected.entryID == entry.id)
        #expect(selected.url == "http://proxy-a.example:8080")
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
