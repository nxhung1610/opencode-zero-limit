import Combine
import Foundation
import RelayDockCore

enum ProxyAppTab: String, CaseIterable, Identifiable {
    case routing
    case pool

    var id: String { rawValue }

    var title: String {
        switch self {
        case .routing: "Routing"
        case .pool: "Proxy Pool"
        }
    }

    var symbol: String {
        switch self {
        case .routing: "arrow.left.arrow.right"
        case .pool: "list.bullet"
        }
    }
}

@MainActor
final class ProxyAppModel: ObservableObject {
    @Published private(set) var state: ProxyState?
    @Published private(set) var loadError: String?
    @Published private(set) var isTesting = false
    @Published var isManualChooserPresented = false
    @Published private(set) var errorMessage: String?
    @Published var selectedTab: ProxyAppTab = .routing

    private let store: ProxyStore

    init(store: ProxyStore = ProxyStore()) {
        self.store = store
    }

    var enabledCount: Int { state?.enabledProxies.count ?? 0 }
    var eligibleCount: Int { state?.autoEligibleProxies.count ?? 0 }
    var manualCandidates: [ProxyEntry] { state?.validEnabledProxies ?? [] }

    /// True when Manual mode can be selected without presenting the chooser.
    var manualSelectionIsUsable: Bool {
        guard let state else { return false }
        return state.manualId.map { id in
            state.validEnabledProxies.contains(where: { $0.id == id })
        } ?? false
    }

    func load() {
        do {
            state = try store.load()
            loadError = nil
        } catch {
            state = nil
            loadError = error.localizedDescription
        }
    }

    func reload() {
        load()
    }

    func selectMode(_ mode: ProxyMode) {
        guard let current = state else { return }
        if mode == .manual, !manualSelectionIsUsable {
            if manualCandidates.isEmpty {
                errorMessage = "Import or enable a valid proxy before selecting Manual mode."
            } else {
                isManualChooserPresented = true
            }
            return
        }
        saveMode(mode, manualID: current.manualId)
    }

    func selectManualProxy(_ id: String) {
        saveMode(.manual, manualID: id)
        if state?.mode == .manual, state?.manualId == id {
            isManualChooserPresented = false
        }
    }

    func setEnabled(_ id: String, enabled: Bool) {
        do {
            state = try store.setEnabled(id, enabled: enabled)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func removeProxy(_ id: String) {
        do {
            state = try store.remove(id)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Returns nil on success, or a validation/persistence message while preserving the caller's input.
    func importProxies(_ text: String) -> String? {
        do {
            state = try store.importProxies(text)
            errorMessage = nil
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// Adds one proxy URL. Returns nil on success, or a message while preserving the caller's input.
    func addProxyURL(_ input: String) -> String? {
        do {
            state = try store.addProxyURL(input)
            errorMessage = nil
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// Adds a custom JavaScript entry. Returns nil on success, or a message while preserving the caller's input.
    func addProxyScript(name: String, script: String) -> String? {
        do {
            state = try store.addProxyScript(name: name, script: script)
            errorMessage = nil
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// Updates a custom JavaScript entry in place. Returns nil on success, or a message while preserving the caller's input.
    func updateProxyScript(id: String, name: String, script: String) -> String? {
        do {
            state = try store.updateProxyScript(id: id, name: name, script: script)
            errorMessage = nil
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func testAll() async {
        guard !isTesting, state != nil else { return }
        isTesting = true
        defer { isTesting = false }
        // RelayDock Edge owns the live script cache. Share the file so a
        // check here never re-fetches a snapshot Edge resolved (and never trips
        // the provider's cooldown for Edge's next rotation), then merge what
        // this check learned back so Edge reuses it too. In P2 the app reads
        // Edge's status directly and this file becomes an implementation
        // detail of Edge.
        let cacheFileURL = store.fileURL.deletingLastPathComponent().appending(path: ScriptCacheFile.fileName)
        if let current = state {
            importProxyScriptCacheSnapshots(ScriptCacheFile.load(from: cacheFileURL).snapshots(matching: current))
        }
        do {
            let checked = try await store.checkAll()
            state = checked
            errorMessage = nil
            let exported = ScriptCacheFile.make(snapshots: exportProxyScriptCacheSnapshots(), state: checked)
            try? ScriptCacheFile.load(from: cacheFileURL).merged(with: exported).save(to: cacheFileURL)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func clearError() {
        errorMessage = nil
    }

    private func saveMode(_ mode: ProxyMode, manualID: String?) {
        do {
            state = try store.setMode(mode, manualId: manualID)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
