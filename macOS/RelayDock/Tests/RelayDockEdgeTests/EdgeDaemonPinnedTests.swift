import Darwin
import Foundation
import RelayDockCore
import Testing
@testable import RelayDockEdge

/// Pinned-listener routing (P3 per-account ports). The decision path never
/// touches the network: a static entry resolves straight from its URL.
struct EdgeDaemonPinnedTests {
    private func makeFixture() throws -> (directory: URL, store: ProxyStore, daemon: EdgeDaemon) {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "relaydock-pinned-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = ProxyStore(configDirectory: directory)
        let config = EdgeConfigFile(port: 57999)
        let log = EdgeLog(url: directory.appending(path: "edge.log"))
        return (directory, store, EdgeDaemon(config: config, directory: directory, log: log))
    }

    @Test func pinnedRouteServesAStaticEntry() async throws {
        let (directory, store, daemon) = try makeFixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let imported = try store.importProxies("http://proxy-a.example:8080")
        let entry = imported.proxies[0]

        guard case .upstream(let upstream) = await daemon.decideRoute(pinning: entry.id) else {
            Issue.record("a pinned static entry must resolve to its URL")
            return
        }
        #expect(upstream.entryID == entry.id)
        #expect(upstream.url == entry.url)
        #expect(upstream.source == "static")
    }

    @Test func pinnedRouteRefusesAMissingEntry() async throws {
        let (directory, store, daemon) = try makeFixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try store.importProxies("http://proxy-a.example:8080")

        guard case .refuse(let reason, _) = await daemon.decideRoute(pinning: "px_missing") else {
            Issue.record("an unknown pin must refuse")
            return
        }
        #expect(reason.contains("no longer in the pool"))
    }

    @Test func pinnedRouteRefusesADisabledEntry() async throws {
        let (directory, store, daemon) = try makeFixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let imported = try store.importProxies("http://proxy-a.example:8080")
        let entry = imported.proxies[0]
        _ = try store.setEnabled(entry.id, enabled: false)

        guard case .refuse(let reason, _) = await daemon.decideRoute(pinning: entry.id) else {
            Issue.record("a disabled pin must refuse")
            return
        }
        #expect(reason.contains("disabled"))
    }

    @Test func pinnedRouteIgnoresTheGlobalOffMode() async throws {
        let (directory, store, daemon) = try makeFixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let imported = try store.importProxies("http://proxy-a.example:8080")
        let entry = imported.proxies[0]
        _ = try store.setMode(.off, manualId: nil)

        guard case .upstream = await daemon.decideRoute(pinning: entry.id) else {
            Issue.record("a pinned listener is an explicit binding; the pool mode never applies")
            return
        }
    }

    @Test func pinnedDialFailuresStrikeOutAndRecover() async throws {
        let (directory, store, daemon) = try makeFixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let imported = try store.importProxies("http://proxy-a.example:8080")
        let entry = imported.proxies[0]

        guard case .upstream = await daemon.decideRoute(pinning: entry.id) else {
            Issue.record("the pinned entry must resolve first")
            return
        }
        #expect(await daemon.notePinnedDialFailure(entryID: entry.id))
        #expect(await daemon.notePinnedDialFailure(entryID: entry.id))
        #expect(!(await daemon.notePinnedDialFailure(entryID: entry.id)))

        await daemon.notePinnedSuccess(entryID: entry.id)
        guard case .upstream = await daemon.decideRoute(pinning: entry.id) else {
            Issue.record("a static pin must be servable again after a reset")
            return
        }
    }

    /// A pinned listener is an explicit one-account binding: even with the
    /// pool's direct fallback on, a broken pin refuses — never direct.
    @Test func pinnedListenersNeverFallBackToDirect() async throws {
        let (directory, store, daemon) = try makeFixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try store.importProxies("http://proxy-a.example:8080")
        _ = try store.setDirectFallback(true)

        guard case .refuse(let reason, _) = await daemon.decideRoute(pinning: "px_missing") else {
            Issue.record("a pinned listener must refuse — never a direct fallback")
            return
        }
        #expect(reason.contains("no longer in the pool"))
    }

    /// A script resolved only through a pinned listener must survive an Edge
    /// restart like any other resolution — otherwise the next Test All reads
    /// the entry as "nothing resolved yet".
    @Test func pinnedScriptResolutionIsPersistedForTheNextProcess() async throws {
        let (directory, store, daemon) = try makeFixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = "cache.url = 'http://127.0.0.1:9'; return cache.url;"
        let imported = try store.addProxyScript(name: "Pinned script", script: script)
        let entry = imported.proxies[0]
        defer { removeProxyScriptCacheSnapshot(for: entry.id) }

        guard case .upstream(let upstream) = await daemon.decideRoute(pinning: entry.id) else {
            Issue.record("a pinned script entry must resolve through its script")
            return
        }
        #expect(upstream.source == "script")

        let file = ScriptCacheFile.load(from: directory.appending(path: ScriptCacheFile.fileName))
        guard let persisted = file.entries[entry.id] else {
            Issue.record("a pinned resolution must persist its snapshot")
            return
        }
        #expect(persisted.scriptHash == ScriptCacheFile.scriptHash(script))
        #expect(persisted.snapshot.contains("127.0.0.1:9"))
    }

    /// A pinned listener caches its own resolution. An edit must invalidate
    /// that endpoint immediately, even when the old snapshot carries a long
    /// expiry the cache would otherwise honor.
    @Test func editingAPinnedScriptDropsItsCachedResolution() async throws {
        let (directory, store, daemon) = try makeFixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = """
        cache.url = "http://old.example:8080";
        cache.expiresAt = Date.now() + 3600000;
        return cache.url;
        """
        let added = try store.addProxyScript(name: "Pinned rotation", script: script)
        let entry = added.proxies[0]
        defer { removeProxyScriptCacheSnapshot(for: entry.id) }

        guard case .upstream(let first) = await daemon.decideRoute(pinning: entry.id) else {
            Issue.record("the pinned script should resolve")
            return
        }
        #expect(first.url == "http://old.example:8080")

        _ = try store.updateProxyScript(
            id: entry.id,
            name: "Pinned rotation",
            script: "return 'http://new.example:8080';"
        )
        guard case .upstream(let second) = await daemon.decideRoute(pinning: entry.id) else {
            Issue.record("the edited pinned script should resolve again")
            return
        }
        #expect(second.url == "http://new.example:8080")
    }

    /// Attribution and free-usage reports must carry the listener's own port;
    /// using the primary `edge.json` port made pinned tunnels unmatchable.
    @Test func pinnedServerConnectionsCarryTheirOwnListenerPort() throws {
        let (directory, _, daemon) = try makeFixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let server = try EdgeServer(
            config: EdgeConfigFile(port: 57_999),
            daemon: daemon,
            log: EdgeLog(url: directory.appending(path: "edge.log")),
            role: .pinned(entryID: "px_a"),
            port: 58_123
        )
        var pair: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else {
            Issue.record("socketpair failed")
            return
        }
        defer { close(pair[1]) }

        let connection = server.makeClientConnection(clientFD: pair[0], peerPort: 40_001)
        #expect(connection.edgePort == 58_123)
    }
}
