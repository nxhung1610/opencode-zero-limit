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
}
