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

    private func makeStore() -> (URL, ProxyStore) {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        return (directory, ProxyStore(configDirectory: directory))
    }
}
