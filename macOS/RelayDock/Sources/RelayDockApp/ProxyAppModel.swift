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

private struct FreeUsageProbeJob: Sendable {
    var entry: ProxyEntry
    var proxyURL: String
}

private struct FreeUsageProbeCompletion: Sendable {
    var entry: ProxyEntry
    var outcome: OpenCodeFreeUsageProbe.Outcome
}

@MainActor
final class ProxyAppModel: ObservableObject {
    @Published private(set) var state: ProxyState?
    @Published private(set) var loadError: String?
    @Published private(set) var isTesting = false
    @Published private(set) var freeUsageProbeStatuses: [String: FreeUsageProbeStatus] = [:]
    @Published var isManualChooserPresented = false
    @Published private(set) var errorMessage: String?
    /// A calm note about what the last Test All skipped — a script entry with
    /// nothing resolved yet is not an error, so it never enters `errorMessage`
    /// (which drives the modal alert). The pool header renders it.
    @Published private(set) var checkNotice: String?
    @Published var selectedTab: ProxyAppTab = .routing
    /// The RelayDock Edge panel, refreshed by `pollEdgeStatusWhileVisible()`.
    /// It lives in its own observable so polling only redraws the rows that show
    /// it; `edgePanel` stays as a read-only view of the current value.
    let edgeStatus = EdgePanelModel()
    var edgePanel: EdgePanelState { edgeStatus.panel }
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
    private let freeModelProvider: @Sendable () async -> String?
    private let freeUsageProbe: @Sendable (ProxyEntry, String, EdgeConfigFile, String) async -> OpenCodeFreeUsageProbe.Outcome
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
        },
        freeModelProvider: @escaping @Sendable () async -> String? = {
            await OpenCodeFreeUsageProbe.findFreeModel()
        },
        freeUsageProbe: @escaping @Sendable (ProxyEntry, String, EdgeConfigFile, String) async -> OpenCodeFreeUsageProbe.Outcome = { entry, proxyURL, config, model in
            await OpenCodeFreeUsageProbe.run(entry: entry, proxyURL: proxyURL, edgeConfig: config, model: model)
        }
    ) {
        self.store = store
        self.updates = updates ?? UpdateModel(configDirectory: store.fileURL.deletingLastPathComponent())
        self.routingSetup = routingSetup ?? RoutingSetupModel(storeDirectory: store.fileURL.deletingLastPathComponent())
        self.edgeStatusProvider = edgeStatusProvider
        self.edgeCheckRunner = edgeCheckRunner
        self.routingProbe = routingProbe
        self.freeModelProvider = freeModelProvider
        self.freeUsageProbe = freeUsageProbe
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
        freeUsageProbeStatuses = [:]
        do {
            state = try store.loadWithFreeUsageLimits()
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
        // Every probe stamps a fresh `checkedAt`; only a changed routing picture
        // should redraw the window.
        if report.servers != openCodeRouting?.servers
            || report.inspectionIncomplete != openCodeRouting?.inspectionIncomplete {
            openCodeRouting = report
        }
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
            freeUsageProbeStatuses = [:]
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
            freeUsageProbeStatuses = [:]
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Returns nil on success, or a validation/persistence message while preserving the caller's input.
    func importProxies(_ text: String) -> String? {
        do {
            state = try store.importProxies(text)
            freeUsageProbeStatuses = [:]
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
            freeUsageProbeStatuses = [:]
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
            freeUsageProbeStatuses = [:]
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
            freeUsageProbeStatuses = [:]
            errorMessage = nil
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func testAll() async {
        guard !isTesting, state != nil else { return }
        isTesting = true
        freeUsageProbeStatuses = [:]
        defer { isTesting = false }
        var quotaProbe: (config: EdgeConfigFile, healthyEntryIDs: Set<String>)?
        // Edge owns the script cache and the checks that feed it: delegate so
        // the provider sees one checker. When Edge does not answer — not
        // installed, not running — fall back to the in-process path and let
        // the pool view say so.
        let edgeConfig = loadEdgeConfig()
        if let edgeConfig, let response = await edgeCheckRunner(edgeConfig) {
            await applyEdgeCheckResults(response)
            refreshProxyStateFromDisk()
            let healthyIDs = Set(response.results.compactMap { entryID, result in
                result.ok && !result.deferred ? entryID : nil
            })
            quotaProbe = (edgeConfig, healthyIDs)
        } else {
            lastCheckRoute = .inApp
            await runInAppChecks()
            refreshProxyStateFromDisk()
            if (state?.proxies ?? []).contains(where: {
                $0.enabled && $0.hasValidDefinition && $0.health?.ok == true && !$0.isFreeUsageLimited()
            }) {
                let reason = edgeConfig == nil ? "RelayDock Edge is not configured" : "RelayDock Edge is not responding"
                appendCheckNotice("OpenCode free-limit probe skipped: \(reason); only proxy connectivity was checked.")
            }
        }
        if let quotaProbe {
            await runOpenCodeFreeUsageProbes(edgeConfig: quotaProbe.config, healthyEntryIDs: quotaProbe.healthyEntryIDs)
        }
    }

    /// Test All first checks proxy connectivity, then sends one small OpenCode
    /// request through an isolated Edge containing only each healthy entry.
    private func runOpenCodeFreeUsageProbes(edgeConfig: EdgeConfigFile, healthyEntryIDs: Set<String>) async {
        let candidates = (state?.proxies ?? []).filter {
            healthyEntryIDs.contains($0.id)
                && $0.enabled && $0.hasValidDefinition && $0.health?.ok == true && !$0.isFreeUsageLimited()
        }
        guard !candidates.isEmpty else { return }
        freeUsageProbeStatuses = Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, .checking) })

        guard let model = await freeModelProvider() else {
            for entry in candidates { freeUsageProbeStatuses[entry.id] = .skipped }
            appendCheckNotice("OpenCode free-limit probe skipped: no available OpenCode free model was found.")
            return
        }

        let scriptCacheURL = store.fileURL.deletingLastPathComponent().appending(path: ScriptCacheFile.fileName)
        if let current = state {
            importProxyScriptCacheSnapshots(ScriptCacheFile.load(from: scriptCacheURL).snapshots(matching: current))
        }

        var jobs: [FreeUsageProbeJob] = []
        for entry in candidates {
            guard let proxyURL = openCodeProbeProxyURL(for: entry) else {
                freeUsageProbeStatuses[entry.id] = .skipped
                continue
            }
            jobs.append(FreeUsageProbeJob(entry: entry, proxyURL: proxyURL))
        }

        // A small concurrency cap keeps several temporary Edge daemons and
        // OpenCode processes from overwhelming the host while still allowing
        // independent proxies to finish and update their rows in parallel.
        let maxConcurrentProbes = 3
        let probe = freeUsageProbe
        await withTaskGroup(of: FreeUsageProbeCompletion.self) { group in
            var nextIndex = 0
            for _ in 0..<min(maxConcurrentProbes, jobs.count) {
                let job = jobs[nextIndex]
                nextIndex += 1
                group.addTask {
                    let outcome = await probe(job.entry, job.proxyURL, edgeConfig, model)
                    return FreeUsageProbeCompletion(entry: job.entry, outcome: outcome)
                }
            }

            while let completion = await group.next() {
                recordFreeUsageProbeOutcome(completion.outcome, for: completion.entry)
                if nextIndex < jobs.count {
                    let job = jobs[nextIndex]
                    nextIndex += 1
                    group.addTask {
                        let outcome = await probe(job.entry, job.proxyURL, edgeConfig, model)
                        return FreeUsageProbeCompletion(entry: job.entry, outcome: outcome)
                    }
                }
            }
        }

        // Each completed probe publishes its row result immediately; reload
        // once more after the group drains to catch any final sidecar changes.
        refreshProxyStateFromDisk()
        let limitedIDs = Set(candidates.compactMap { entry in
            state?.proxies.first(where: { $0.id == entry.id })?.isFreeUsageLimited() == true ? entry.id : nil
        })
        let failures = candidates.filter { freeUsageProbeStatuses[$0.id] == .failed }.count
        let skipped = candidates.filter { freeUsageProbeStatuses[$0.id] == .skipped }.count
        let limited = limitedIDs.count
        var messages: [String] = []
        if limited > 0 {
            messages.append("OpenCode FreeUsageLimitError: paused \(limited) proxy \(limited == 1 ? "until reset" : "proxies until reset").")
        }
        if failures > 0 {
            messages.append("OpenCode quota probe failed for \(failures) healthy proxy \(failures == 1 ? "entry" : "entries").")
        }
        if skipped > 0 {
            messages.append("OpenCode quota probe skipped for \(skipped) healthy custom \(skipped == 1 ? "entry" : "entries") without a cached proxy URL.")
        }
        if jobs.isEmpty && skipped == 0 {
            messages.append("OpenCode quota probe could not find a healthy proxy to test.")
        }
        if !messages.isEmpty { appendCheckNotice(messages.joined(separator: " ")) }
    }

    private func recordFreeUsageProbeOutcome(_ outcome: OpenCodeFreeUsageProbe.Outcome, for entry: ProxyEntry) {
        switch outcome {
        case .passed:
            freeUsageProbeStatuses[entry.id] = .passed
        case .failed, .timedOut:
            freeUsageProbeStatuses[entry.id] = .failed
        case .freeUsageLimited(let retryAfterMs):
            let deadline = Date().timeIntervalSince1970 + retryAfterMs / 1_000
            do {
                try FreeUsageLimitStore(configDirectory: store.fileURL.deletingLastPathComponent())
                    .flag(entry.id, until: deadline)
                freeUsageProbeStatuses.removeValue(forKey: entry.id)
                refreshProxyStateFromDisk()
            } catch {
                freeUsageProbeStatuses[entry.id] = .failed
            }
        }
    }

    private func openCodeProbeProxyURL(for entry: ProxyEntry) -> String? {
        if entry.script != nil {
            guard let cachedURL = proxyScriptCachedURL(for: entry.id) else { return nil }
            return parseProxyImportLine(cachedURL)
        }
        return parseProxyImportLine(entry.url)
    }

    private func appendCheckNotice(_ message: String) {
        if let existing = checkNotice, !existing.isEmpty {
            checkNotice = existing + " " + message
        } else {
            checkNotice = message
        }
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
        let next: EdgePanelState
        if let config = loadEdgeConfig() {
            next = if let status = await edgeStatusProvider(config) {
                .running(status)
            } else {
                .notRunning
            }
        } else {
            next = .notConfigured
        }
        edgeStatus.apply(next)
    }

    /// Polls the daemon while a surface is visible; views drive this from
    /// `.task`, so closing the window or the menu bar popover cancels it.
    func pollEdgeStatusWhileVisible() async {
        while !Task.isCancelled {
            refreshProxyStateFromDisk()
            await refreshEdgeStatus()
            if state?.mode != .off { await refreshOpenCodeRouting() }
            do {
                try await Task.sleep(for: .seconds(3))
            } catch {
                return
            }
        }
    }

    /// Edge records free-tier cooldowns in its sidecar while OpenCode is
    /// running. Refresh the visible pool from disk so the flag appears without
    /// requiring the user to close and reopen RelayDock.
    func refreshProxyStateFromDisk() {
        guard let latest = try? store.loadWithFreeUsageLimits(), latest != state else { return }
        state = latest
    }

    /// Recent tunnels grouped by client process — the panel's "who used Edge"
    /// list. Processes with active tunnels sort first, then by last activity.
    var edgeAttribution: [EdgeAttribution] { edgeStatus.edgeAttribution }

    /// Seeds the panel without touching the network (fixtures and tests).
    func applyEdgePanelForFixtures(_ panel: EdgePanelState) {
        edgeStatus.apply(panel)
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
