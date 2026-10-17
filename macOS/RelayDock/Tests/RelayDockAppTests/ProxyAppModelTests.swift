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

    private func makeStore() -> (URL, ProxyStore) {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        return (directory, ProxyStore(configDirectory: directory))
    }
}
