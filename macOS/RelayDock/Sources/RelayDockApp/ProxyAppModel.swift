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
    /// A calm note about what the last Test All skipped — a script entry with
    /// nothing resolved yet is not an error, so it never enters `errorMessage`
    /// (which drives the modal alert). The pool header renders it.
    @Published private(set) var checkNotice: String?
    @Published var selectedTab: ProxyAppTab = .routing
    /// The RelayDock Edge panel, refreshed by `pollEdgeStatusWhileVisible()`.
    @Published private(set) var edgePanel: EdgePanelState = .unknown
    /// Which checker the last Test All used — the pool view says so out loud
    /// when Edge is unreachable and the check fell back in-process.
    @Published private(set) var lastCheckRoute: CheckRoute?
    @Published private(set) var openCodeRouting: OpenCodeRoutingSnapshot?
    @Published private(set) var isCheckingOpenCodeRouting = false
    @Published private(set) var pendingRoutingChange: PendingRoutingChange?

    private let store: ProxyStore
    /// The updater's lifecycle; the footer rows render it, nothing else mutates it.
    let updates: UpdateModel
    /// The Routing page's setup section (install/uninstall the PATH wrapper).
    let routingSetup: RoutingSetupModel
    private let edgeStatusProvider: @Sendable (EdgeConfigFile) async -> EdgeStatusResponse?
    private let edgeCheckRunner: @Sendable (EdgeConfigFile) async -> EdgeCheckResponse?
    private let routingProbe: @Sendable (EdgeConfigFile?) async -> OpenCodeRoutingSnapshot
    private var routingProbeTask: Task<OpenCodeRoutingSnapshot, Never>?
    private var modeChangeID = UUID()
    private var modeChangeSource: RoutingChangeSource?

    init(
        store: ProxyStore = ProxyStore(),
        updates: UpdateModel? = nil,
        routingSetup: RoutingSetupModel? = nil,
        edgeStatusProvider: @escaping @Sendable (EdgeConfigFile) async -> EdgeStatusResponse? = { config in
            await EdgeStatusClient.fetchStatusAsync(config: config)
        },
        edgeCheckRunner: @escaping @Sendable (EdgeConfigFile) async -> EdgeCheckResponse? = { config in
            await EdgeStatusClient.runChecksAsync(config: config, scope: .all)
        },
        routingProbe: @escaping @Sendable (EdgeConfigFile?) async -> OpenCodeRoutingSnapshot = { config in
            await OpenCodeRoutingProbe.inspect(edgeConfig: config)
        }
    ) {
        self.store = store
        self.updates = updates ?? UpdateModel(configDirectory: store.fileURL.deletingLastPathComponent())
        self.routingSetup = routingSetup ?? RoutingSetupModel(storeDirectory: store.fileURL.deletingLastPathComponent())
        self.edgeStatusProvider = edgeStatusProvider
        self.edgeCheckRunner = edgeCheckRunner
        self.routingProbe = routingProbe
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

    func selectMode(_ mode: ProxyMode, source: RoutingChangeSource = .window) async {
        guard let current = state else { return }
        if mode == .off {
            modeChangeID = UUID()
            pendingRoutingChange = nil
            isCheckingOpenCodeRouting = false
            saveMode(mode, manualID: current.manualId)
            return
        }
        guard !isCheckingOpenCodeRouting, pendingRoutingChange == nil else { return }
        guard current.mode != mode else { return }
        if mode == .manual, !manualSelectionIsUsable {
            if manualCandidates.isEmpty {
                errorMessage = "Import or enable a valid proxy before selecting Manual mode."
            } else {
                isManualChooserPresented = true
            }
            return
        }
        await requestRoutingChange(mode: mode, manualID: current.manualId, source: source)
    }

    func selectManualProxy(_ id: String, source: RoutingChangeSource = .window) async {
        guard !isCheckingOpenCodeRouting, pendingRoutingChange == nil else { return }
        guard state?.mode != .manual || state?.manualId != id else { return }
        await requestRoutingChange(mode: .manual, manualID: id, source: source)
    }

    private func requestRoutingChange(mode: ProxyMode, manualID: String?, source: RoutingChangeSource) async {
        guard let current = state else { return }
        let id = UUID()
        modeChangeID = id
        modeChangeSource = source
        isCheckingOpenCodeRouting = true
        defer { if modeChangeID == id { isCheckingOpenCodeRouting = false } }
        let report = await refreshOpenCodeRouting(force: true)
        guard !Task.isCancelled, modeChangeID == id else { return }
        let request = PendingRoutingChange(
            id: id, mode: mode, manualID: manualID,
            previousMode: current.mode, previousManualID: current.manualId,
            source: source, report: report
        )
        if !report.affectedServers.isEmpty {
            pendingRoutingChange = request
        } else {
            // Unknown is not a pass: the notice remains visible after saving,
            // but a lack of evidence alone must not produce a bypass popup.
            commitRoutingChange(request)
        }
    }

    func cancelRoutingChange(_ id: UUID) {
        guard pendingRoutingChange?.id == id else { return }
        pendingRoutingChange = nil
        modeChangeID = UUID()
    }

    func cancelRoutingChanges(from source: RoutingChangeSource) {
        guard modeChangeSource == source else { return }
        modeChangeID = UUID()
        pendingRoutingChange = nil
        isCheckingOpenCodeRouting = false
    }

    func confirmRoutingChange(_ request: PendingRoutingChange) {
        guard pendingRoutingChange?.id == request.id, modeChangeID == request.id else { return }
        commitRoutingChange(request)
        pendingRoutingChange = nil
    }

    private func commitRoutingChange(_ request: PendingRoutingChange) {
        guard modeChangeID == request.id else { return }
        do {
            // Re-read policy after the probe/dialog; another surface or app
            // instance must not have its newer mode overwritten by this one.
            let latest = try store.load()
            guard latest.mode == request.previousMode, latest.manualId == request.previousManualID else {
                state = latest
                errorMessage = "Routing settings changed while checking OpenCode. Please choose the mode again."
                return
            }
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        saveMode(request.mode, manualID: request.manualID)
        if request.mode == .manual, state?.mode == .manual, state?.manualId == request.manualID {
            isManualChooserPresented = false
        }
    }

    @discardableResult
    func refreshOpenCodeRouting(force: Bool = false) async -> OpenCodeRoutingSnapshot {
        if let task = routingProbeTask { return await task.value }
        if !force, let report = openCodeRouting, Date().timeIntervalSince1970 - report.checkedAt < 10 {
            return report
        }
        let probe = routingProbe
        let config = loadEdgeConfig()
        let task = Task { await probe(config) }
        routingProbeTask = task
        let report = await task.value
        openCodeRouting = report
        routingProbeTask = nil
        return report
    }

    var hasOpenCodeRoutingNotice: Bool {
        guard let state, state.mode != .off, let report = openCodeRouting else { return false }
        return !report.affectedServers.isEmpty || report.isUnverified
    }

    func setEnabled(_ id: String, enabled: Bool) {
        do {
            state = try store.setEnabled(id, enabled: enabled)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// The opt-in direct fallback — saved policy, read live by Edge.
    func setDirectFallback(_ enabled: Bool) {
        do {
            state = try store.setDirectFallback(enabled)
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
        // Edge owns the script cache and the checks that feed it: delegate so
        // the provider sees one checker. When Edge does not answer — not
        // installed, not running — fall back to the in-process path and let
        // the pool view say so.
        if let config = loadEdgeConfig(), let response = await edgeCheckRunner(config) {
            await applyEdgeCheckResults(response)
            return
        }
        lastCheckRoute = .inApp
        await runInAppChecks()
    }

    private func applyEdgeCheckResults(_ response: EdgeCheckResponse) async {
        var health: [String: ProxyHealth] = [:]
        var deferredByID: [String: String] = [:]
        for (id, result) in response.results {
            if result.deferred {
                deferredByID[id] = result.error ?? "deferred"
                continue
            }
            health[id] = ProxyHealth(
                ok: result.ok,
                latencyMs: result.latencyMs,
                checkedAt: result.checkedAt,
                error: result.error
            )
        }
        // Pool order, so the notice reads the same as the list below it.
        var skipped: [(label: String, reason: String)] = []
        for proxy in state?.proxies ?? [] {
            if let reason = deferredByID.removeValue(forKey: proxy.id) {
                skipped.append((proxy.label, reason))
            }
        }
        for (id, reason) in deferredByID.sorted(by: { $0.key < $1.key }) {
            skipped.append((id, reason))
        }
        do {
            state = try store.applyCheckResults(health)
            lastCheckRoute = .edge
            checkNotice = Self.skippedCheckNotice(skipped)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        await refreshEdgeStatus()
    }

    /// One line naming what Test All skipped and why: skipped checks are by
    /// design (nothing to probe), so they read as a note, not as an error.
    static func skippedCheckNotice(_ skipped: [(label: String, reason: String)]) -> String? {
        guard let first = skipped.first else { return nil }
        let count = skipped.count
        let labels = skipped.map(\.label)
        let named = labels.count > 3
            ? labels.prefix(3).joined(separator: ", ") + ", …"
            : labels.joined(separator: ", ")
        return "Skipped \(count) check\(count == 1 ? "" : "s") (\(named)): \(first.reason)"
    }

    private func runInAppChecks() async {
        // Edge is unreachable: run the checks here, but still share the
        // script-cache file so a check never re-fetches a snapshot Edge
        // resolved (and never trips the provider's cooldown for Edge's next
        // rotation), then merge what this check learned back.
        let cacheFileURL = store.fileURL.deletingLastPathComponent().appending(path: ScriptCacheFile.fileName)
        if let current = state {
            importProxyScriptCacheSnapshots(ScriptCacheFile.load(from: cacheFileURL).snapshots(matching: current))
        }
        do {
            let checked = try await store.checkAll()
            state = checked
            errorMessage = nil
            checkNotice = nil
            let exported = ScriptCacheFile.make(snapshots: exportProxyScriptCacheSnapshots(), state: checked)
            try? ScriptCacheFile.load(from: cacheFileURL).merged(with: exported).save(to: cacheFileURL)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - RelayDock Edge panel

    /// `edge.json` next to `proxies.json` — the file the installer writes and
    /// the launcher hands to wrapped processes.
    private var edgeConfigURL: URL {
        store.fileURL.deletingLastPathComponent().appending(path: "edge.json")
    }

    private func loadEdgeConfig() -> EdgeConfigFile? {
        EdgeConfigFile.load(from: edgeConfigURL)
    }

    /// Refreshes the panel: a missing `edge.json` reads as not configured and
    /// an unanswered poll as not running — never as an error.
    func refreshEdgeStatus() async {
        guard let config = loadEdgeConfig() else {
            edgePanel = .notConfigured
            return
        }
        if let status = await edgeStatusProvider(config) {
            edgePanel = .running(status)
        } else {
            edgePanel = .notRunning
        }
    }

    /// Polls the daemon while a surface is visible; views drive this from
    /// `.task`, so closing the window or the menu bar popover cancels it.
    func pollEdgeStatusWhileVisible() async {
        while !Task.isCancelled {
            await refreshEdgeStatus()
            if state?.mode != .off { await refreshOpenCodeRouting() }
            do {
                try await Task.sleep(for: .seconds(3))
            } catch {
                return
            }
        }
    }

    /// Recent tunnels grouped by client process — the panel's "who used Edge"
    /// list. Processes with active tunnels sort first, then by last activity.
    var edgeAttribution: [EdgeAttribution] {
        guard case .running(let status) = edgePanel else { return [] }
        var byKey: [String: EdgeAttribution] = [:]
        for tunnel in status.tunnels {
            let key = tunnel.peerPid.map(String.init) ?? "unknown"
            var summary = byKey[key] ?? EdgeAttribution(
                id: key,
                name: tunnel.peerName ?? "Unknown process",
                pid: tunnel.peerPid,
                tunnels: 0,
                activeTunnels: 0,
                bytesDown: 0,
                lastActivity: tunnel.startedAt
            )
            summary.tunnels += 1
            if tunnel.active { summary.activeTunnels += 1 }
            summary.bytesDown += tunnel.bytesDown
            summary.lastActivity = max(summary.lastActivity, tunnel.endedAt ?? tunnel.startedAt)
            byKey[key] = summary
        }
        return byKey.values.sorted { lhs, rhs in
            if (lhs.activeTunnels > 0) != (rhs.activeTunnels > 0) {
                return lhs.activeTunnels > 0
            }
            return lhs.lastActivity > rhs.lastActivity
        }
    }

    /// Seeds the panel without touching the network (fixtures and tests).
    func applyEdgePanelForFixtures(_ panel: EdgePanelState) {
        edgePanel = panel
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
