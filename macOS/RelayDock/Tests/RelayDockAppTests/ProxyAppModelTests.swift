import Foundation
import RelayDockCore
import Testing
@testable import RelayDockApp

struct ProxyAppModelTests {
    @Test @MainActor func manualModeRequiresAnExplicitEnabledProxy() throws {
        let (directory, store) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let imported = try store.importProxies("http://proxy.example:8080")
        let model = ProxyAppModel(store: store)
        model.load()

        model.selectMode(.manual)

        #expect(model.state?.mode == .off)
        #expect(model.isManualChooserPresented)

        model.selectManualProxy(imported.proxies[0].id)

        #expect(model.state?.mode == .manual)
        #expect(model.state?.manualId == imported.proxies[0].id)
        #expect(!model.isManualChooserPresented)
    }

    @Test @MainActor func unreadableConfigurationDoesNotAppearAsDirectOff() throws {
        let (directory, store) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(#"{"mode":"manual","proxies":[}"#.utf8).write(to: store.fileURL)
        let model = ProxyAppModel(store: store)

        model.load()

        #expect(model.state == nil)
        #expect(model.loadError != nil)
    }

    @Test @MainActor func invalidImportPreservesExistingPoolAndReportsError() throws {
        let (directory, store) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let initial = try store.importProxies("http://proxy.example:8080")
        let model = ProxyAppModel(store: store)
        model.load()

        let error = model.importProxies("ftp://unsupported.example:21")

        #expect(error?.contains("line 1") == true)
        #expect(model.state == initial)
    }

    @Test @MainActor func manualSelectionUsabilityTracksEnabledAndValidState() throws {
        let (directory, store) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let imported = try store.importProxies("http://proxy.example:8080")
        let model = ProxyAppModel(store: store)
        model.load()

        #expect(!model.manualSelectionIsUsable)

        model.selectManualProxy(imported.proxies[0].id)
        #expect(model.manualSelectionIsUsable)

        model.setEnabled(imported.proxies[0].id, enabled: false)
        #expect(!model.manualSelectionIsUsable)
    }

    @Test @MainActor func manualModeSwitchesDirectlyWhenSelectionIsUsable() throws {
        let (directory, store) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let imported = try store.importProxies("http://proxy.example:8080")
        let model = ProxyAppModel(store: store)
        model.load()
        model.selectManualProxy(imported.proxies[0].id)
        model.selectMode(.off)

        model.selectMode(.manual)

        #expect(model.state?.mode == .manual)
        #expect(!model.isManualChooserPresented)
    }

    @Test @MainActor func testAllSharesTheEdgeScriptCacheOnDisk() async throws {
        let (directory, store) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let state = try store.addProxyScript(
            name: "Edge cache",
            script: """
            if (cache.url) { return cache.url; }
            throw new Error('the script must not run when the Edge cache has a snapshot');
            """
        )
        let entryID = state.proxies[0].id
        let snapshot = #"{"url":"http://127.0.0.1:9101"}"#
        let cacheFileURL = directory.appending(path: ScriptCacheFile.fileName)
        var seeded = ScriptCacheFile.make(snapshots: [entryID: snapshot], state: state)
        seeded.entries["px_someone_else"] = .init(scriptHash: "other", snapshot: #"{"keep":1}"#)
        try seeded.save(to: cacheFileURL)

        let model = ProxyAppModel(store: store)
        model.load()
        await model.testAll()

        // The snapshot came from the file, not from running the failing script.
        let health = model.state?.proxies.first(where: { $0.id == entryID })?.health
        #expect(health?.ok == false)
        #expect(health?.error?.contains("must not run") == false)

        // The export merged back without dropping a snapshot only the file had.
        let remaining = ScriptCacheFile.load(from: cacheFileURL)
        #expect(remaining.entries[entryID]?.snapshot.contains("9101") == true)
        #expect(remaining.entries["px_someone_else"]?.snapshot == #"{"keep":1}"#)
    }

    @Test @MainActor func testAllDelegatesToEdgeAndPersistsItsResults() async throws {
        let (directory, store) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let imported = try store.importProxies("http://proxy.example:8080")
        let entryID = imported.proxies[0].id
        try writeEdgeConfig(in: directory)
        let checkedAt = Date().timeIntervalSince1970 * 1_000
        let model = ProxyAppModel(
            store: store,
            edgeStatusProvider: { _ in nil },
            edgeCheckRunner: { _ in
                EdgeCheckResponse(results: [
                    entryID: .init(ok: true, latencyMs: 42, checkedAt: checkedAt),
                ])
            }
        )
        model.load()

        await model.testAll()

        #expect(model.lastCheckRoute == .edge)
        let health = model.state?.proxies.first(where: { $0.id == entryID })?.health
        #expect(health?.ok == true)
        #expect(health?.latencyMs == 42)
    }

    @Test @MainActor func testAllFallsBackInProcessWhenEdgeIsNotConfigured() async throws {
        let (directory, store) = makeStore(checker: { _ in
            ProxyHealth(ok: true, latencyMs: 5, checkedAt: 1)
        })
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try store.importProxies("http://proxy.example:8080")
        let model = ProxyAppModel(
            store: store,
            edgeStatusProvider: { _ in nil },
            edgeCheckRunner: { _ in nil }
        )
        model.load()

        await model.testAll()

        #expect(model.lastCheckRoute == .inApp)
        #expect(model.state?.proxies.first?.health?.ok == true)
    }

    @Test @MainActor func testAllFallsBackInProcessWhenEdgeDoesNotAnswer() async throws {
        let (directory, store) = makeStore(checker: { _ in
            ProxyHealth(ok: true, latencyMs: 5, checkedAt: 1)
        })
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try store.importProxies("http://proxy.example:8080")
        try writeEdgeConfig(in: directory)
        let model = ProxyAppModel(
            store: store,
            edgeStatusProvider: { _ in nil },
            edgeCheckRunner: { _ in nil }
        )
        model.load()

        await model.testAll()

        #expect(model.lastCheckRoute == .inApp)
        #expect(model.state?.proxies.first?.health?.ok == true)
    }

    @Test @MainActor func refreshEdgeStatusTracksConfigurationAndLiveness() async throws {
        let (directory, store) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        try writeEdgeConfig(in: directory)
        let status = EdgeStatusResponse(pid: 1, port: 1, mode: .off, launchedAt: 0)
        let live = ProxyAppModel(
            store: store,
            edgeStatusProvider: { _ in status },
            edgeCheckRunner: { _ in nil }
        )
        await live.refreshEdgeStatus()
        #expect(live.edgePanel == .running(status))

        let down = ProxyAppModel(store: store, edgeStatusProvider: { _ in nil }, edgeCheckRunner: { _ in nil })
        await down.refreshEdgeStatus()
        #expect(down.edgePanel == .notRunning)

        try FileManager.default.removeItem(at: directory.appending(path: "edge.json"))
        let unconfigured = ProxyAppModel(store: store, edgeStatusProvider: { _ in nil }, edgeCheckRunner: { _ in nil })
        await unconfigured.refreshEdgeStatus()
        #expect(unconfigured.edgePanel == .notConfigured)
    }

    @Test @MainActor func edgeAttributionGroupsTunnelsByPeer() async throws {
        let (directory, store) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        try writeEdgeConfig(in: directory)
        let now = Date().timeIntervalSince1970
        let status = EdgeStatusResponse(
            pid: 10,
            port: 1,
            mode: .auto,
            counters: .init(tunnelsTotal: 3, tunnelsActive: 1),
            tunnels: [
                .init(clientPort: 1, peerPid: 100, peerName: "opencode", startedAt: now - 60, bytesDown: 1_000, active: true),
                .init(clientPort: 2, peerPid: 100, peerName: "opencode", startedAt: now - 600, endedAt: now - 500, bytesDown: 2_000, active: false),
                .init(clientPort: 3, peerPid: nil, peerName: nil, startedAt: now - 900, endedAt: now - 800, bytesDown: 4_000, active: false),
            ],
            launchedAt: now - 3_600
        )
        let model = ProxyAppModel(store: store, edgeStatusProvider: { _ in status }, edgeCheckRunner: { _ in nil })

        await model.refreshEdgeStatus()

        let attribution = model.edgeAttribution
        #expect(attribution.count == 2)
        #expect(attribution[0].pid == 100)
        #expect(attribution[0].tunnels == 2)
        #expect(attribution[0].activeTunnels == 1)
        #expect(attribution[0].bytesDown == 3_000)
        #expect(attribution[1].name == "Unknown process")
    }

    private func writeEdgeConfig(in directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let json = #"{"version":1,"port":57211,"token":"app-model-test-token"}"#
        try Data(json.utf8).write(to: directory.appending(path: "edge.json"))
    }

    private func makeStore(
        checker: (@Sendable (String) async -> ProxyHealth)? = nil
    ) -> (URL, ProxyStore) {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let store = checker.map { ProxyStore(configDirectory: directory, healthChecker: $0) }
            ?? ProxyStore(configDirectory: directory)
        return (directory, store)
    }
}
