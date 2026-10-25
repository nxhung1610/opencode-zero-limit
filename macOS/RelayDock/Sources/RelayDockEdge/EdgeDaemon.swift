import Darwin
import Foundation
import RelayDockCore

/// A concrete upstream in use, plus its provenance for status and logs.
struct EdgeUpstream: Equatable, Sendable {
    var entryID: String
    var label: String
    /// Concrete proxy URL, possibly with credentials. Never logged raw.
    var url: String
    /// `"script"` or `"static"`.
    var source: String
    var resolvedAt: Double
    var expiresAt: Double?
    /// When the next new connection should proactively refresh, if the
    /// lifetime is known.
    var refreshAt: Double?
    var strikes: Int
}

enum EdgeRouteDecision {
    case direct
    /// The pool's opt-in direct fallback: no proxy is usable and the state
    /// explicitly allows direct. The relay labels the tunnel and counts it —
    /// this is never chosen silently.
    case directFallback(reason: String)
    case upstream(EdgeUpstream)
    case refuse(reason: String, retryAt: Double?)
}

enum EdgeCheckOutcome: Sendable {
    case ok(ProxyHealth)
    case failed(ProxyHealth)
    case deferred(reason: String, retryAfter: TimeInterval)
}

enum EdgeCheckScope: Sendable {
    case active
    case all
    case entries([String])
}

enum EdgeFreeUsageLimitReport: Equatable, Sendable {
    case flagged(entryID: String, retryAt: Double)
    case unmatched
    case invalidCooldown
    case persistenceFailed
}

/// How an established upstream tunnel ended badly after its dial succeeded.
enum EdgeTunnelFailure: Equatable, Sendable {
    /// The upstream side errored mid-session (reset or abort after the
    /// tunnel was up).
    case died
    /// Request bytes reached the upstream, not a single response byte came
    /// back, and the client gave up after the stall window.
    case stalled(duration: TimeInterval)

    var summary: String {
        switch self {
        case .died:
            "tunnel died mid-stream"
        case .stalled(let duration):
            "zero-byte stall (\(Int(duration))s)"
        }
    }
}

/// All mutable Edge state and the routing policy. A single actor serializes
/// decisions; the operations that can block for seconds (script runs, health
/// checks) hop to detached tasks so no connection ever waits behind them.
actor EdgeDaemon {
    struct TunnelRecord: Sendable {
        var clientPort: UInt16
        var edgePort: UInt16
        var entryID: String?
        var label: String?
        var peerPid: Int32?
        var peerName: String?
        var startedAt: Double
        var endedAt: Double?
        var bytesUp: Int
        var bytesDown: Int
        var active: Bool
    }

    private struct ResolveOutcome: Sendable {
        enum Kind: Sendable {
            case success(upstream: EdgeUpstream, isNewBinding: Bool)
            case throttled(retryAt: Double, message: String)
            case failed(message: String)
            case modeChanged
        }
        var kind: Kind
    }

    let config: EdgeConfigFile
    let log: EdgeLog
    private let directory: URL
    private let attribution = EdgeAttribution()
    private let launchedAt = Date().timeIntervalSince1970

    private var cachedState: ProxyState?
    private var cachedStateMtime: Date?
    private var cachedFreeUsageLimitMtime: Date?
    private var stateEverLoaded = false
    private var bindings: [String: String] = [:]
    private var upstream: EdgeUpstream?
    /// The manual selection the cached `upstream` and the throttle/backoff
    /// gates belong to. A new selection must never inherit the previous
    /// entry's cooldown (or its cached endpoint).
    private var lastSelectionKey: String?
    private var autoUpstreams: [String: EdgeUpstream] = [:]
    private var autoResolveTasks: [String: Task<ResolveOutcome, Never>] = [:]
    private var autoRetryAtByEntry: [String: Double] = [:]
    private var autoErrors: [String: String] = [:]
    private var autoLastEntryID: String?
    private var lastAutoFailureAt: [String: Double] = [:]
    private var resolveTask: Task<ResolveOutcome, Never>?
    private var throttleRetryAt: Double?
    private var resolveBackoffUntil: Double = 0
    private var pendingReason: String?
    private var lastErrors: [String] = []
    private var liveHealth: [String: ProxyHealth] = [:]
    private var lastCacheImportMtime: Date?
    private var legacyCacheAdopted = false
    private var scriptHashes: [String: String] = [:]
    private var resolutions = 0
    private var switches = 0
    private var dialFailures = 0
    private var streamFailures = 0
    private var directFallbacks = 0
    private var tunnelsTotal = 0
    private var lastDialFailureAt: Double = 0
    private var tunnelsActive: [UInt16: TunnelRecord] = [:]
    private var tunnelsRecent: [TunnelRecord] = []
    private var nextCheckAt: [String: Double] = [:]
    private var failureStreak: [String: Int] = [:]
    private var schedulerTask: Task<Void, Never>?
    private var pinnedUpstreams: [String: EdgeUpstream] = [:]
    private var pinnedResolveTasks: [String: (generation: Int, task: Task<EdgeUpstream?, Never>)] = [:]
    /// Bumped when an entry's script changes. An in-flight pinned resolve
    /// captured the old script, so its result must never be cached.
    private var pinnedResolveGeneration: [String: Int] = [:]
    private var pinnedErrors: [String: String] = [:]
    private var hopPool: [String: [(socket: EdgeSocket, createdAt: Double)]] = [:]
    private let hopPoolLifetime: TimeInterval = 20
    private let hopPoolDepth = 1
    private let listenerReport: EdgeListenerReport?

    init(
        config: EdgeConfigFile,
        directory: URL,
        log: EdgeLog,
        listenerReport: EdgeListenerReport? = nil
    ) {
        self.config = config
        self.directory = directory
        self.log = log
        self.listenerReport = listenerReport
    }

    // MARK: - State file

    private var stateURL: URL { directory.appending(path: "proxies.json") }

    /// Reads `proxies.json` with an mtime cache. A damaged file keeps the
    /// last good configuration and never breaks live traffic; only a file
    /// that was never readable at all returns nil (callers then refuse).
    private func loadState() -> ProxyState? {
        let url = stateURL
        let freeUsageLimits = FreeUsageLimitStore(configDirectory: directory)
        let limitMtime = freeUsageLimits.modificationDate
        guard FileManager.default.fileExists(atPath: url.path) else {
            stateEverLoaded = true
            let state = freeUsageLimits.applying(to: .defaults)
            cachedState = state
            cachedStateMtime = nil
            cachedFreeUsageLimitMtime = limitMtime
            return state
        }
        let mtime = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        if let cachedState, mtime == cachedStateMtime, limitMtime == cachedFreeUsageLimitMtime {
            return cachedState
        }
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(ProxyState.self, from: data) else {
            log.warn("proxies.json is unreadable; keeping the last good configuration")
            return stateEverLoaded ? cachedState : nil
        }
        let state = freeUsageLimits.applying(to: decoded)
        if !stateEverLoaded { bindings = state.bindings }
        stateEverLoaded = true
        cachedState = state
        cachedStateMtime = mtime
        cachedFreeUsageLimitMtime = limitMtime
        handleScriptEdits(in: state)
        return state
    }

    // MARK: - Script cache (shared with the app during P1)

    private func syncScriptCacheFromDisk(state: ProxyState, force: Bool) {
        let primary = directory.appending(path: ScriptCacheFile.fileName)
        let legacy = directory.appending(path: ScriptCacheFile.legacyFileName)
        let mtime = (try? FileManager.default.attributesOfItem(atPath: primary.path))?[.modificationDate] as? Date
        if !force, let mtime, mtime == lastCacheImportMtime { return }
        if mtime == nil, !FileManager.default.fileExists(atPath: primary.path), !legacyCacheAdopted {
            // One-time adoption of the spawn-time launcher's cache file.
            legacyCacheAdopted = true
            let legacyFile = ScriptCacheFile.load(from: legacy)
            if !legacyFile.entries.isEmpty {
                importProxyScriptCacheSnapshots(legacyFile.snapshots(matching: state))
                lastCacheImportMtime = nil
                log.info("adopted \(ScriptCacheFile.legacyFileName) into the Edge script cache")
                return
            }
        }
        let file = ScriptCacheFile.load(from: primary)
        importProxyScriptCacheSnapshots(file.snapshots(matching: state))
        lastCacheImportMtime = mtime
    }

    private func persistScriptCache(state: ProxyState) {
        let primary = directory.appending(path: ScriptCacheFile.fileName)
        let fresh = ScriptCacheFile.make(snapshots: exportProxyScriptCacheSnapshots(), state: state)
        let merged = ScriptCacheFile.load(from: primary).merged(with: fresh)
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try merged.save(to: primary)
            lastCacheImportMtime = (try? FileManager.default.attributesOfItem(atPath: primary.path))?[.modificationDate] as? Date
        } catch {
            log.warn("could not persist the script cache: \(error.localizedDescription)")
        }
    }

    /// A script edit must never keep serving the endpoint the old script
    /// produced: the in-memory `cache` object is keyed by entry id, so compare
    /// each script against the hash seen last and drop both the cached
    /// snapshot and the live upstream the moment the text changes. The next
    /// request re-resolves with the new script.
    private func handleScriptEdits(in state: ProxyState) {
        var editedIDs: [String] = []
        for proxy in state.proxies {
            guard let script = proxy.script else { continue }
            let hash = ScriptCacheFile.scriptHash(script)
            if let known = scriptHashes[proxy.id], known != hash {
                editedIDs.append(proxy.id)
            }
            scriptHashes[proxy.id] = hash
        }
        let scriptIDs = Set(state.proxies.filter { $0.script != nil }.map(\.id))
        scriptHashes = scriptHashes.filter { scriptIDs.contains($0.key) }
        pinnedResolveGeneration = pinnedResolveGeneration.filter { scriptIDs.contains($0.key) }
        for id in editedIDs {
            removeProxyScriptCacheSnapshot(for: id)
            autoUpstreams[id] = nil
            autoErrors[id] = nil
            autoRetryAtByEntry[id] = nil
            // A pinned listener caches its own resolution. Drop it, and
            // invalidate any resolve that started with the old script.
            pinnedUpstreams[id] = nil
            pinnedErrors[id] = nil
            pinnedResolveGeneration[id, default: 0] += 1
            if state.mode == .manual, state.manualId == id {
                // The cooldown belonged to the old script; the new one must
                // get a chance to resolve on the next connection.
                throttleRetryAt = nil
                resolveBackoffUntil = 0
            }
            if upstream?.entryID == id {
                upstream = nil
                pendingReason = nil
            }
            log.info("script edited; dropped the cached state for entry \(id)")
        }
    }

    // MARK: - Selection

    /// Auto eligibility uses Edge's live health view where it exists (a fresh
    /// failure excludes an entry even if the file says ok — and a fresh
    /// success re-includes one the file still marks failed: recovery without
    /// a manual re-test).
    private func stateForSelection(_ state: ProxyState) -> ProxyState {
        var selection = state
        for index in selection.proxies.indices {
            if let health = liveHealth[selection.proxies[index].id] {
                selection.proxies[index].health = health
            }
        }
        return selection
    }

    private func needsResolve(state: ProxyState, now: Double) -> Bool {
        guard let upstream else { return true }
        if upstream.strikes >= 3 { return true }
        if let refreshAt = upstream.refreshAt, now >= refreshAt { return true }
        if !state.proxies.contains(where: { $0.id == upstream.entryID && $0.enabled && $0.hasValidDefinition }) {
            return true
        }
        if state.mode == .manual, state.manualId != upstream.entryID { return true }
        return false
    }

    /// Identity of the route a decision is for. Cached endpoints and the
    /// global throttle/backoff gates belong to exactly one selection; when
    /// this changes, the old state must be dropped. Same-entry re-resolves
    /// (`strikes`, `refreshAt`) keep the same key, which is what preserves
    /// stale-while-error.
    private func selectionKey(_ state: ProxyState, now: Double) -> String {
        switch state.mode {
        case .off:
            return "off"
        case .auto:
            return "auto"
        case .manual:
            guard let id = state.manualId else { return "manual|-" }
            guard let entry = state.proxies.first(where: { $0.id == id }) else {
                return "manual|\(id)|missing"
            }
            guard entry.enabled, entry.hasValidDefinition else {
                return "manual|\(id)|invalid"
            }
            guard !entry.isFreeUsageLimited(at: now) else {
                return "manual|\(id)|limited"
            }
            return "manual|\(id)|ok"
        }
    }

    private static func defaultRefusal(_ state: ProxyState) -> String {
        state.mode == .manual ? "no usable proxy is selected" : "no proxy in the pool is usable"
    }

    // MARK: - Routing

    func decideRoute(pinning entryID: String? = nil) async -> EdgeRouteDecision {
        if let entryID { return await pinnedRoute(for: entryID) }
        let now = Date().timeIntervalSince1970
        guard let state = loadState() else {
            return .refuse(reason: "proxies.json could not be read on this Mac", retryAt: nil)
        }
        let key = selectionKey(state, now: now)
        let changed = key != lastSelectionKey
        lastSelectionKey = key
        if changed, state.mode == .manual {
            // Fail closed: a cached endpoint from another selection (or from
            // an entry that is now disabled, removed, or limited) must not be
            // served. Same-entry refresh failures keep the key, so the
            // documented stale-while-error behavior still applies.
            upstream = nil
            pendingReason = nil
            throttleRetryAt = nil
            resolveBackoffUntil = 0
        }
        if state.mode == .off { return .direct }
        if state.mode == .auto {
            return await autoRoute(state: state)
        }
        if let selected = state.proxies.first(where: { $0.id == state.manualId }),
           selected.isFreeUsageLimited(at: now),
           let retryAt = selected.freeUsageLimitedUntil {
            let reason = "proxy \(selected.label) is paused after an OpenCode free-usage limit"
            pendingReason = reason
            throttleRetryAt = retryAt
            return .refuse(reason: reason, retryAt: retryAt)
        }
        if needsResolve(state: state, now: now) {
            if let outcome = await resolveLocked(state: state),
               case .success(let resolved, _) = outcome.kind {
                return .upstream(resolved)
            }
        }
        if let upstream { return .upstream(upstream) }
        if let retryAt = throttleRetryAt, retryAt > now {
            let reason = pendingReason ?? "the provider is cooling down"
            if state.directFallback { return .directFallback(reason: reason) }
            return .refuse(reason: reason, retryAt: retryAt)
        }
        let reason = pendingReason ?? Self.defaultRefusal(state)
        if state.directFallback { return .directFallback(reason: reason) }
        return .refuse(reason: reason, retryAt: nil)
    }

    /// Auto mode rotates eligible proxies at the new-tunnel boundary. The
    /// cursor advances before any script resolution awaits, so concurrent
    /// connections do not all claim the same next slot. HTTPS remains opaque:
    /// one established CONNECT tunnel always keeps its chosen upstream.
    private func autoRoute(state: ProxyState, excluding excludedIDs: Set<String> = []) async -> EdgeRouteDecision {
        let selection = stateForSelection(state)
        let now = Date().timeIntervalSince1970
        let eligible = selection.autoEligibleProxies(at: now)
        let validIDs = Set(selection.validEnabledProxies.map(\.id))
        autoUpstreams = autoUpstreams.filter { validIDs.contains($0.key) }
        autoRetryAtByEntry = autoRetryAtByEntry.filter { validIDs.contains($0.key) }
        autoErrors = autoErrors.filter { validIDs.contains($0.key) }
        if let current = upstream, !validIDs.contains(current.entryID) {
            upstream = nil
        }

        // Warm-up and Manual may already have resolved the first pool entry.
        // Reuse that endpoint, but Auto's cursor—not the sticky account binding—
        // controls all subsequent tunnel choices.
        if let current = upstream, validIDs.contains(current.entryID), autoUpstreams[current.entryID] == nil {
            autoUpstreams[current.entryID] = current
        }
        if eligible.contains(where: \.isCustomScript) {
            syncScriptCacheFromDisk(state: state, force: lastCacheImportMtime == nil)
        }

        var attempted = excludedIDs
        var resolutionErrors: [String] = []
        let ordered = Self.orderedAutoProxies(eligible, after: autoLastEntryID)
        for entry in ordered where !attempted.contains(entry.id) {
            // Advance before awaiting script work; actor reentrancy must not
            // hand the same cursor position to simultaneous new connections.
            autoLastEntryID = entry.id
            if let retryAt = autoRetryAtByEntry[entry.id], retryAt > now {
                attempted.insert(entry.id)
                if let message = autoErrors[entry.id] { resolutionErrors.append(message) }
                continue
            }
            autoRetryAtByEntry[entry.id] = nil
            autoErrors[entry.id] = nil

            if let cached = autoUpstreams[entry.id],
               cached.refreshAt.map({ now >= $0 }) != true,
               cached.expiresAt.map({ now >= $0 }) != true {
                selectAutoUpstream(cached)
                return .upstream(cached)
            }

            let outcome = await resolveAutoEntry(entry)
            switch outcome.kind {
            case .success(let resolved, _):
                let completedAt = Date().timeIntervalSince1970
                var adjusted = resolved
                if let previous = autoUpstreams[entry.id],
                   previous.url == resolved.url,
                   previous.expiresAt == resolved.expiresAt,
                   let previousRefresh = previous.refreshAt,
                   completedAt >= previousRefresh {
                    adjusted.refreshAt = completedAt + 30
                }
                autoUpstreams[entry.id] = adjusted
                autoRetryAtByEntry[entry.id] = nil
                autoErrors[entry.id] = nil
                resolutions += 1
                selectAutoUpstream(adjusted)
                if adjusted.source == "script" {
                    persistScriptCache(state: loadState() ?? .defaults)
                }
                return .upstream(adjusted)
            case .throttled(let retryAt, let message):
                autoRetryAtByEntry[entry.id] = retryAt
                autoErrors[entry.id] = message
                resolutionErrors.append(message)
            case .failed(let message):
                autoRetryAtByEntry[entry.id] = Date().timeIntervalSince1970 + 15
                autoErrors[entry.id] = message
                resolutionErrors.append(message)
            case .modeChanged:
                break
            }
            attempted.insert(entry.id)
        }

        let retryAt = (autoRetryAtByEntry.values.filter { $0 > now }
            + selection.validEnabledProxies.compactMap(\.freeUsageLimitedUntil).filter { $0 > now }).min()
        throttleRetryAt = retryAt
        let hasLimitedProxy = selection.validEnabledProxies.contains { $0.isFreeUsageLimited(at: now) }
        let reason = resolutionErrors.first
            ?? (eligible.isEmpty && hasLimitedProxy
                ? "all usable proxies are paused until their OpenCode free-usage limit resets"
                : (excludedIDs.isEmpty ? Self.defaultRefusal(state) : "no other eligible proxy is available to retry this connection"))
        pendingReason = reason
        if state.directFallback { return .directFallback(reason: reason) }
        return .refuse(reason: reason, retryAt: retryAt)
    }

    private func resolveAutoEntry(_ entry: ProxyEntry) async -> ResolveOutcome {
        if let task = autoResolveTasks[entry.id] { return await task.value }
        let placement = ProxyState(mode: .manual, manualId: entry.id, proxies: [entry])
        let directory = self.directory
        let log = self.log
        let task = Task.detached(priority: .userInitiated) {
            Self.performResolve(selection: placement, bindings: [:], directory: directory, log: log)
        }
        autoResolveTasks[entry.id] = task
        let outcome = await task.value
        autoResolveTasks[entry.id] = nil
        return outcome
    }

    private func selectAutoUpstream(_ resolved: EdgeUpstream) {
        if let previous = upstream {
            if previous.entryID != resolved.entryID {
                switches += 1
                log.info("switched upstream to \(resolved.label) (\(maskedProxyURL(resolved.url)))")
            }
            if previous.entryID != resolved.entryID || previous.url != resolved.url {
                drainHopPool()
            }
        }
        upstream = resolved
        pendingReason = nil
        throttleRetryAt = nil
        resolveBackoffUntil = 0
    }

    static func orderedAutoProxies(_ entries: [ProxyEntry], after entryID: String?) -> [ProxyEntry] {
        guard !entries.isEmpty,
              let entryID,
              let index = entries.firstIndex(where: { $0.id == entryID }) else { return entries }
        let start = (index + 1) % entries.count
        return Array(entries[start...]) + Array(entries[..<start])
    }

    /// Whether the pool's opt-in direct fallback is enabled — read live from
    /// `proxies.json` like every other routing decision. The connection
    /// handler consults this once its dial-retry contract runs out.
    func directFallbackEnabled() -> Bool {
        loadState()?.directFallback == true
    }

    func refusalReason(pinning entryID: String? = nil) -> String? {
        if let entryID { return pinnedErrors[entryID] }
        return pendingReason
    }

    /// Seconds a refused client should wait before retrying, while the
    /// policy sits inside a timed provider cooldown. Nil when no timed wait
    /// applies — the absence of the header means "retry whenever".
    func refusalRetryAfter() -> TimeInterval? {
        let now = Date().timeIntervalSince1970
        guard let retryAt = throttleRetryAt, retryAt > now else { return nil }
        return retryAt - now
    }

    // MARK: - Pinned listeners (per-account ports)

    /// Route decision for a listener pinned to one entry: the global mode
    /// deliberately does not apply (a pinned port exists to serve exactly
    /// this account), and nothing else in the pool is ever considered.
    /// Failures refuse — never a different entry, never a direct dial.
    private func pinnedRoute(for entryID: String) async -> EdgeRouteDecision {
        let now = Date().timeIntervalSince1970
        guard let state = loadState() else {
            return .refuse(reason: "proxies.json could not be read on this Mac", retryAt: nil)
        }
        guard let entry = state.proxies.first(where: { $0.id == entryID }) else {
            return .refuse(reason: "the pinned entry \(entryID) is no longer in the pool", retryAt: nil)
        }
        guard entry.enabled, entry.hasValidDefinition else {
            return .refuse(
                reason: "the pinned entry \"\(entry.label)\" is disabled or has no usable definition",
                retryAt: nil
            )
        }
        if entry.isFreeUsageLimited(at: now), let retryAt = entry.freeUsageLimitedUntil {
            let reason = "pinned proxy \(entry.label) is paused after an OpenCode free-usage limit"
            pinnedErrors[entryID] = reason
            return .refuse(reason: reason, retryAt: retryAt)
        }
        if let cached = pinnedUpstreams[entryID], cached.strikes < 3,
           let refreshAt = cached.refreshAt, now < refreshAt {
            return .upstream(cached)
        }
        if let resolved = await resolvePinned(entry: entry) { return .upstream(resolved) }
        if let cached = pinnedUpstreams[entryID], cached.strikes < 3 { return .upstream(cached) }
        return .refuse(
            reason: pinnedErrors[entryID] ?? "the pinned entry could not resolve an upstream",
            retryAt: nil
        )
    }

    /// The loopback plugin reports a provider-level free-tier error. Match it
    /// to the freshest tunnel from the same OpenCode process; do not infer a
    /// route from timing alone when process attribution is unavailable.
    func reportFreeUsageLimit(
        retryAfterMs: Double,
        reportClientPort: UInt16?,
        edgePort: UInt16,
        explicitEntryID: String? = nil,
        now: Double = Date().timeIntervalSince1970
    ) -> EdgeFreeUsageLimitReport {
        guard Self.validFreeUsageCooldown(retryAfterMs), now.isFinite else { return .invalidCooldown }
        // OpenCode's Test All probe intentionally uses the selected upstream
        // directly so it cannot rotate onto another healthy pool member. Its
        // loopback plugin report therefore carries the explicit tested entry.
        // Normal OpenCode sessions still require same-process tunnel matching.
        if let explicitEntryID, !explicitEntryID.isEmpty {
            guard let reportClientPort,
                  let reporter = attribution.peer(forClientPort: reportClientPort, edgePort: edgePort),
                  Self.isOpenCodeProcessName(reporter.name) else { return .unmatched }
            return persistFreeUsageLimit(entryID: explicitEntryID, retryAfterMs: retryAfterMs, now: now)
        }
        guard let reportClientPort,
              let reporter = attribution.peer(forClientPort: reportClientPort, edgePort: edgePort),
              let tunnel = Self.matchingTunnel(
                peerPID: reporter.pid,
                edgePort: edgePort,
                active: Array(tunnelsActive.values),
                recent: tunnelsRecent,
                now: now
              ),
              let entryID = tunnel.entryID else { return .unmatched }
        return persistFreeUsageLimit(entryID: entryID, retryAfterMs: retryAfterMs, now: now)
    }

    /// Persists the matched proxy's cooldown. Kept internal for deterministic
    /// tests; live reports go through `reportFreeUsageLimit` above.
    func persistFreeUsageLimit(
        entryID: String,
        retryAfterMs: Double,
        now: Double = Date().timeIntervalSince1970
    ) -> EdgeFreeUsageLimitReport {
        guard Self.validFreeUsageCooldown(retryAfterMs), now.isFinite else { return .invalidCooldown }
        guard let state = loadState(), state.proxies.contains(where: { $0.id == entryID }) else {
            return .unmatched
        }

        let store = FreeUsageLimitStore(configDirectory: directory)
        do {
            let retryAt = try store.flag(entryID, until: now + retryAfterMs / 1_000)
            cachedState = store.applying(to: state, now: now)
            cachedFreeUsageLimitMtime = store.modificationDate
            let label = state.proxies.first(where: { $0.id == entryID })?.label ?? entryID
            log.warn("OpenCode FreeUsageLimitError: paused \(label) for \(Int((retryAt - now).rounded()))s")
            pushError("OpenCode free-usage limit via \(label); paused until \(Int(retryAt))")
            return .flagged(entryID: entryID, retryAt: retryAt)
        } catch {
            log.error("could not persist OpenCode free-usage cooldown for \(entryID): \(error.localizedDescription)")
            return .persistenceFailed
        }
    }

    static func validFreeUsageCooldown(_ retryAfterMs: Double) -> Bool {
        retryAfterMs.isFinite && (1_000...604_800_000).contains(retryAfterMs)
    }

    static func isOpenCodeProcessName(_ name: String) -> Bool {
        name.caseInsensitiveCompare("opencode") == .orderedSame
    }

    static func matchingTunnel(
        peerPID: Int32,
        edgePort: UInt16,
        active: [TunnelRecord],
        recent: [TunnelRecord],
        now: Double
    ) -> TunnelRecord? {
        let candidates = (active + recent).filter { tunnel in
            guard tunnel.peerPid == peerPID,
                  tunnel.edgePort == edgePort,
                  tunnel.entryID != nil,
                  tunnel.startedAt <= now else { return false }
            if tunnel.active { return true }
            let endedAt = tunnel.endedAt ?? tunnel.startedAt
            return endedAt <= now && now - endedAt <= 120
        }
        return candidates.max { $0.startedAt < $1.startedAt }
    }

    /// Single-flight resolve of one pinned entry through the standard route
    /// machinery (a forced manual selection over a state that contains only
    /// this entry), caching the result the way the pool-wide resolve does.
    private func resolvePinned(entry: ProxyEntry) async -> EdgeUpstream? {
        if let pending = pinnedResolveTasks[entry.id] {
            let resolved = await pending.task.value
            guard pinnedResolveGeneration[entry.id, default: 0] == pending.generation else {
                // The joining caller must discard the old script's result too,
                // not just the caller that created the task. Only clear the
                // cache while this is still the newest resolve: once a newer
                // task exists, its snapshot must survive.
                if pinnedResolveTasks[entry.id]?.generation == pending.generation {
                    removeProxyScriptCacheSnapshot(for: entry.id)
                }
                return nil
            }
            return resolved
        }
        let generation = pinnedResolveGeneration[entry.id, default: 0]
        var placement = ProxyState.defaults
        placement.mode = .manual
        placement.manualId = entry.id
        placement.proxies = [entry]
        let log = self.log
        let task = Task.detached(priority: .userInitiated) { () -> EdgeUpstream? in
            Self.performPinnedResolve(placement: placement, entry: entry, log: log)
        }
        pinnedResolveTasks[entry.id] = (generation, task)
        let resolved = await task.value
        if pinnedResolveTasks[entry.id]?.generation == generation {
            pinnedResolveTasks[entry.id] = nil
        }
        guard pinnedResolveGeneration[entry.id, default: 0] == generation else {
            // The script changed while the old one was running. Its cache
            // snapshot may have been written after the edit cleared it, so
            // remove it again before refusing.
            removeProxyScriptCacheSnapshot(for: entry.id)
            return nil
        }
        if let resolved {
            pinnedUpstreams[entry.id] = resolved
            pinnedErrors[entry.id] = nil
            // A pinned resolution is a resolution: persist it so it survives
            // an Edge restart the way a pool-wide one does — otherwise the
            // entry reads as "nothing resolved yet" on the next Test All.
            if entry.isCustomScript {
                persistScriptCache(state: loadState() ?? .defaults)
            }
        } else if pinnedErrors[entry.id] == nil {
            pinnedErrors[entry.id] = "the pinned entry \"\(entry.label)\" could not resolve an upstream"
        }
        return resolved
    }

    private static func performPinnedResolve(
        placement: ProxyState,
        entry: ProxyEntry,
        log: EdgeLog
    ) -> EdgeUpstream? {
        do {
            guard let route = try resolveSpawnRoute(state: placement, accountID: "pinned", bindings: [:]),
                  route.entryID == entry.id else { return nil }
            let now = Date().timeIntervalSince1970
            let snapshot = exportProxyScriptCacheSnapshots()[entry.id]
            var expiresAt: Double?
            var refreshAt: Double?
            if let expiry = snapshotExpiry(snapshot: snapshot, now: now) {
                expiresAt = expiry
                let lifetime = max(expiry - now, 1)
                refreshAt = expiry - min(60, max(10, lifetime / 10))
            }
            let resolved = EdgeUpstream(
                entryID: entry.id,
                label: entry.label,
                url: route.proxyURL,
                source: entry.isCustomScript ? "script" : "static",
                resolvedAt: now,
                expiresAt: expiresAt,
                refreshAt: refreshAt,
                strikes: 0
            )
            let expiryNote = expiresAt.map { ", expires in \(Int($0 - now))s" } ?? ""
            log.info("pinned listener resolved \(entry.label) (\(maskedProxyURL(route.proxyURL)))\(expiryNote)")
            return resolved
        } catch {
            log.warn("pinned resolve failed for \(entry.label): \(error.localizedDescription)")
            return nil
        }
    }

    /// A dial through a pinned upstream failed: count it, strike the cached
    /// endpoint (its snapshot is dropped so the next resolve asks fresh), and
    /// report whether the caller may retry once.
    func notePinnedDialFailure(entryID: String) -> Bool {
        dialFailures += 1
        var strikes = 0
        if var cached = pinnedUpstreams[entryID] {
            cached.strikes += 1
            strikes = cached.strikes
            pinnedUpstreams[entryID] = cached
            removeProxyScriptCacheSnapshot(for: entryID)
        }
        pushError("pinned listener dial failed: \(pinnedUpstreams[entryID]?.label ?? entryID)")
        return strikes < 3
    }

    func notePinnedSuccess(entryID: String) {
        guard var cached = pinnedUpstreams[entryID], cached.strikes > 0 else { return }
        cached.strikes = 0
        pinnedUpstreams[entryID] = cached
    }

    @discardableResult
    private func resolveLocked(state: ProxyState) async -> ResolveOutcome? {
        if let resolveTask { return await resolveTask.value }
        let now = Date().timeIntervalSince1970
        if now < resolveBackoffUntil { return nil }
        if let retryAt = throttleRetryAt, now < retryAt { return nil }
        syncScriptCacheFromDisk(state: state, force: lastCacheImportMtime == nil)
        let selection = stateForSelection(state)
        let snapshotBindings = bindings
        let directory = self.directory
        let log = self.log
        let task = Task.detached(priority: .userInitiated) {
            Self.performResolve(selection: selection, bindings: snapshotBindings, directory: directory, log: log)
        }
        resolveTask = task
        let outcome = await task.value
        resolveTask = nil
        apply(outcome)
        return outcome
    }

    private static func performResolve(
        selection: ProxyState,
        bindings: [String: String],
        directory: URL,
        log: EdgeLog
    ) -> ResolveOutcome {
        do {
            guard let route = try resolveSpawnRoute(state: selection, accountID: "default", bindings: bindings),
                  let entry = selection.proxies.first(where: { $0.id == route.entryID }) else {
                return ResolveOutcome(kind: .modeChanged)
            }
            let now = Date().timeIntervalSince1970
            let snapshot = exportProxyScriptCacheSnapshots()[entry.id]
            var expiresAt: Double?
            var refreshAt: Double?
            if let expiry = snapshotExpiry(snapshot: snapshot, now: now) {
                expiresAt = expiry
                let lifetime = max(expiry - now, 1)
                refreshAt = expiry - min(60, max(10, lifetime / 10))
            }
            let resolved = EdgeUpstream(
                entryID: route.entryID,
                label: entry.label,
                url: route.proxyURL,
                source: entry.isCustomScript ? "script" : "static",
                resolvedAt: now,
                expiresAt: expiresAt,
                refreshAt: refreshAt,
                strikes: 0
            )
            let expiryNote = expiresAt.map { ", expires in \(Int($0 - now))s" } ?? ""
            log.info("resolved \(entry.label) (\(maskedProxyURL(route.proxyURL)))\(expiryNote)")
            return ResolveOutcome(kind: .success(upstream: resolved, isNewBinding: route.isNewBinding))
        } catch {
            let message = error.localizedDescription
            if let retryAfter = proxyScriptRetryAfterSeconds(from: message) {
                log.warn("provider cooldown: \(message)")
                return ResolveOutcome(
                    kind: .throttled(retryAt: Date().timeIntervalSince1970 + retryAfter, message: message)
                )
            }
            log.warn("resolve failed: \(message)")
            return ResolveOutcome(kind: .failed(message: message))
        }
    }

    /// Looks for a JS-script lifetime in the entry's cache snapshot
    /// (`expiresAt`/`expires_at`/`expiry`/`expireAt`, in ms or seconds).
    /// Absent or implausible values simply mean "lifetime unknown".
    static func snapshotExpiry(snapshot: String?, now: Double) -> Double? {
        guard let snapshot, let data = snapshot.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        for key in ["expiresAt", "expires_at", "expiry", "expireAt"] {
            let raw: Double?
            if let number = object[key] as? NSNumber {
                raw = number.doubleValue
            } else if let text = object[key] as? String {
                raw = Double(text)
            } else {
                raw = nil
            }
            guard let value = raw else { continue }
            let seconds = value > 1e12 ? value / 1000 : value
            if seconds > now + 5 { return seconds }
        }
        return nil
    }

    private func apply(_ outcome: ResolveOutcome) {
        let now = Date().timeIntervalSince1970
        switch outcome.kind {
        case .success(let resolved, let isNewBinding):
            if isNewBinding { bindings["default"] = resolved.entryID }
            var adjusted = resolved
            if let previous = upstream, previous.url == resolved.url, previous.expiresAt == resolved.expiresAt,
               let previousRefresh = previous.refreshAt, now >= previousRefresh {
                // The proactive refresh got the same endpoint back (the script
                // still honors its own cache); don't re-ask on every connection.
                adjusted.refreshAt = now + 30
            }
            if let previous = upstream, previous.entryID != resolved.entryID {
                switches += 1
                log.info("switched upstream to \(resolved.label) (\(maskedProxyURL(resolved.url)))")
                // Warm sockets belong to the old endpoint; drop them.
                drainHopPool()
            }
            resolutions += 1
            upstream = adjusted
            pendingReason = nil
            throttleRetryAt = nil
            resolveBackoffUntil = 0
            persistScriptCache(state: loadState() ?? .defaults)
        case .throttled(let retryAt, let message):
            throttleRetryAt = retryAt
            if upstream == nil { pendingReason = message }
            pushError("deferred: \(message)")
        case .failed(let message):
            resolveBackoffUntil = now + 15
            if upstream == nil { pendingReason = message }
            pushError(message)
        case .modeChanged:
            break
        }
    }

    private func pushError(_ message: String) {
        lastErrors.append(message)
        if lastErrors.count > 10 {
            lastErrors.removeFirst(lastErrors.count - 10)
        }
    }

    // MARK: - Dial outcomes

    /// A dial through `failed` failed. Auto immediately tries the next eligible
    /// entry (excluding this one); Manual keeps its existing single-entry retry
    /// behavior. Route identity is explicit because multiple tunnels can dial
    /// different proxies concurrently.
    func noteDialFailure(for failed: EdgeUpstream, reResolve: Bool) async -> EdgeUpstream? {
        dialFailures += 1
        let now = Date().timeIntervalSince1970
        let state = loadState()
        if state?.mode == .auto {
            let windowOpen = now - (lastAutoFailureAt[failed.entryID] ?? 0) <= 30
            var current = autoUpstreams[failed.entryID] ?? failed
            current.strikes = windowOpen ? current.strikes + 1 : 1
            autoUpstreams[failed.entryID] = current
            if upstream?.entryID == failed.entryID { upstream = current }
            lastAutoFailureAt[failed.entryID] = now
            autoRetryAtByEntry[failed.entryID] = now + 30
            autoErrors[failed.entryID] = "dial failed via \(failed.label)"
            if failed.source == "script" {
                removeProxyScriptCacheSnapshot(for: failed.entryID)
                current.refreshAt = now
                autoUpstreams[failed.entryID] = current
                if upstream?.entryID == failed.entryID { upstream = current }
            }
            guard reResolve, let state else { return nil }
            autoLastEntryID = failed.entryID
            if case .upstream(let replacement) = await autoRoute(state: state, excluding: [failed.entryID]) {
                return replacement
            }
            // A custom script can rotate its endpoint even when it is the
            // pool's only eligible entry. If there was no usable alternate,
            // retry that script once with its stale snapshot removed rather
            // than leaving Auto permanently pinned to the failed URL.
            if failed.source == "script",
               stateForSelection(state).autoEligibleProxies(at: Date().timeIntervalSince1970)
                .contains(where: { $0.id == failed.entryID }) {
                autoRetryAtByEntry[failed.entryID] = nil
                autoErrors[failed.entryID] = nil
                if case .upstream(let replacement) = await autoRoute(state: state) {
                    return replacement
                }
            }
            return nil
        }

        let windowOpen = now - lastDialFailureAt <= 30
        lastDialFailureAt = now
        var current = upstream?.entryID == failed.entryID ? (upstream ?? failed) : failed
        current.strikes = windowOpen ? current.strikes + 1 : 1
        if upstream?.entryID == failed.entryID { upstream = current }
        if reResolve { removeProxyScriptCacheSnapshot(for: failed.entryID) }
        guard reResolve else { return nil }
        let strikes = current.strikes
        if let state, state.mode != .off,
           let outcome = await resolveLocked(state: state) {
            switch outcome.kind {
            case .success(let resolved, _): return resolved
            case .throttled, .failed, .modeChanged: break
            }
        }
        if strikes >= 3 { return nil }
        return upstream
    }

    func noteUpstreamSuccess(entryID: String) {
        if var cached = autoUpstreams[entryID], cached.strikes > 0 {
            cached.strikes = 0
            autoUpstreams[entryID] = cached
        }
        if var current = upstream, current.entryID == entryID, current.strikes > 0 {
            current.strikes = 0
            upstream = current
        }
        autoRetryAtByEntry[entryID] = nil
        autoErrors[entryID] = nil
    }

    /// One more tunnel served by direct fallback (its direct dial succeeded).
    /// The counter and the log line keep the degraded route visible — this
    /// traffic was never proxied, and status must be able to say so.
    func noteDirectFallback(reason: String) {
        directFallbacks += 1
        log.warn("direct fallback: \(reason)")
    }

    /// An established upstream tunnel died mid-stream or stalled. Auto records
    /// the failure against that tunnel's own entry and temporarily skips it;
    /// Manual retains its re-resolve behavior. The in-flight request cannot be
    /// retried because bytes are already in flight.
    func noteTunnelFailure(entryID: String, failure: EdgeTunnelFailure) async {
        streamFailures += 1
        let state = loadState()
        let label = autoUpstreams[entryID]?.label
            ?? (upstream?.entryID == entryID ? (upstream?.label ?? entryID) : entryID)
        pushError("tunnel failed via \(label): \(failure.summary)")
        log.warn("tunnel failed via \(label): \(failure.summary)")
        let now = Date().timeIntervalSince1970
        if state?.mode == .auto {
            let windowOpen = now - (lastAutoFailureAt[entryID] ?? 0) <= 30
            if var current = autoUpstreams[entryID] ?? (upstream?.entryID == entryID ? upstream : nil) {
                current.strikes = windowOpen ? current.strikes + 1 : 1
                if current.source == "script" {
                    current.refreshAt = now
                    removeProxyScriptCacheSnapshot(for: entryID)
                }
                autoUpstreams[entryID] = current
                if upstream?.entryID == entryID { upstream = current }
            }
            lastAutoFailureAt[entryID] = now
            autoRetryAtByEntry[entryID] = now + 30
            autoErrors[entryID] = "tunnel failed via \(label): \(failure.summary)"
            nextCheckAt[entryID] = min(nextCheckAt[entryID] ?? .greatestFiniteMagnitude, now + 30)
            return
        }
        guard upstream?.entryID == entryID else { return }
        let windowOpen = now - lastDialFailureAt <= 30
        lastDialFailureAt = now
        if var current = upstream {
            current.strikes = windowOpen ? current.strikes + 1 : 1
            upstream = current
            removeProxyScriptCacheSnapshot(for: current.entryID)
        }
        // Re-verify the provider soon through a fresh endpoint: the health
        // probe exercises a full request through the proxy, so a zombie
        // provider cannot hide behind an open-but-silent tunnel.
        nextCheckAt[entryID] = min(nextCheckAt[entryID] ?? .greatestFiniteMagnitude, now + 30)
        if let state, state.mode != .off {
            _ = await resolveLocked(state: state)
        }
    }

    // MARK: - Tunnels

    func registerTunnel(clientPort: UInt16?, edgePort: UInt16, entryID: String?, label: String?) {
        tunnelsTotal += 1
        guard let clientPort else { return }
        // Resolve the peer now: the client TCP connection is guaranteed to be
        // established at registration, while a lookup from `status()` may run
        // after the tunnel closed and can no longer be attributed.
        let peer = attribution.peer(forClientPort: clientPort, edgePort: edgePort)
        tunnelsActive[clientPort] = TunnelRecord(
            clientPort: clientPort,
            edgePort: edgePort,
            entryID: entryID,
            // Keep the exact route selected for this connection. The shared
            // `upstream` field can advance while several tunnels are active.
            label: label,
            peerPid: peer?.pid,
            peerName: peer?.name,
            startedAt: Date().timeIntervalSince1970,
            endedAt: nil,
            bytesUp: 0,
            bytesDown: 0,
            active: true
        )
    }

    func finishTunnel(clientPort: UInt16?, bytesUp: Int, bytesDown: Int) {
        guard let clientPort, var record = tunnelsActive.removeValue(forKey: clientPort) else { return }
        record.bytesUp = bytesUp
        record.bytesDown = bytesDown
        record.active = false
        record.endedAt = Date().timeIntervalSince1970
        tunnelsRecent.append(record)
        if tunnelsRecent.count > 64 {
            tunnelsRecent.removeFirst(tunnelsRecent.count - 64)
        }
    }

    // MARK: - Health

    func warmup() async {
        guard let state = loadState() else {
            log.warn("warm-up skipped: proxies.json is unreadable")
            return
        }
        if state.mode == .off {
            log.info("warm-up: proxy mode is Off")
            return
        }
        _ = await resolveLocked(state: state)
    }

    func startScheduler() {
        guard schedulerTask == nil else { return }
        schedulerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30 * 1_000_000_000)
                guard let self else { return }
                await self.runDueChecks()
            }
        }
    }

    private func runDueChecks() async {
        let now = Date().timeIntervalSince1970
        guard let state = loadState(), state.mode != .off else { return }
        var due: [String] = []
        let activeID = upstream?.entryID ?? (state.mode == .manual ? state.manualId : nil)
        if let activeID, state.proxies.contains(where: { $0.id == activeID && $0.enabled }) {
            if now >= (nextCheckAt[activeID] ?? now) { due.append(activeID) }
        }
        for (id, streak) in failureStreak where streak > 0 && !due.contains(id) {
            guard state.proxies.contains(where: { $0.id == id && $0.enabled && $0.hasValidDefinition }) else { continue }
            if now >= (nextCheckAt[id] ?? now) { due.append(id) }
        }
        for id in due {
            _ = await runCheck(entryID: id)
        }
    }

    @discardableResult
    func runCheck(entryID: String) async -> EdgeCheckOutcome? {
        // Checks are diagnostics, not routing: they stay available in Off
        // mode so the app's Test All delegates here in every mode. The
        // scheduler that calls this method on its own still refuses to run
        // while routing is Off.
        guard let state = loadState(),
              let entry = state.proxies.first(where: { $0.id == entryID && $0.enabled }) else { return nil }
        // A check probes what the entry is currently serving, and the
        // resolution Edge persisted to `script-cache.json` is part of that
        // answer: in Off mode warm-up never resolves, and a mode switch (or
        // a restart before the first resolve) leaves the in-memory cache
        // cold while the file still holds the last resolution. One stat once
        // the file is unchanged.
        syncScriptCacheFromDisk(state: state, force: false)
        let outcome = await check(entry: entry)
        let now = Date().timeIntervalSince1970
        switch outcome {
        case .ok(let health):
            liveHealth[entryID] = health
            failureStreak[entryID] = 0
            nextCheckAt[entryID] = now + 600
            let latency = health.latencyMs.map { " (\(Int($0)) ms)" } ?? ""
            log.info("check ok: \(entry.label)\(latency)")
        case .failed(let health):
            liveHealth[entryID] = health
            let streak = (failureStreak[entryID] ?? 0) + 1
            failureStreak[entryID] = streak
            nextCheckAt[entryID] = now + Self.backoffSeconds(streak)
            pushError("check failed: \(entry.label): \(health.error ?? "unknown")")
            log.warn("check failed: \(entry.label): \(health.error ?? "unknown")")
        case .deferred(let reason, let retryAfter):
            // "Nothing to probe yet" (an unresolved script entry) says
            // nothing about the endpoint; it neither marks failed nor
            // clears a failure streak.
            nextCheckAt[entryID] = now + max(retryAfter, 30)
            log.warn("check deferred: \(entry.label): \(reason)")
        }
        return outcome
    }

    func runChecks(scope: EdgeCheckScope) async -> [String: EdgeCheckOutcome] {
        guard let state = loadState() else { return [:] }
        let targets: [ProxyEntry]
        switch scope {
        case .active:
            let activeID = upstream?.entryID ?? (state.mode == .manual ? state.manualId : nil)
            targets = state.proxies.filter { $0.id == activeID }
        case .all:
            targets = state.proxies.filter { $0.enabled && $0.hasValidDefinition }
        case .entries(let ids):
            targets = state.proxies.filter { ids.contains($0.id) }
        }
        var results: [String: EdgeCheckOutcome] = [:]
        for entry in targets {
            if let outcome = await runCheck(entryID: entry.id) {
                results[entry.id] = outcome
            }
        }
        return results
    }

    private static func backoffSeconds(_ streak: Int) -> Double {
        switch streak {
        case 1: return 300
        case 2: return 900
        default: return 3600
        }
    }

    private func check(entry: ProxyEntry) async -> EdgeCheckOutcome {
        if entry.script != nil {
            // A check probes the proxy this entry is currently serving; it
            // never resolves (rotates) the script. Rotation belongs to the
            // router — launch, expiry, death recovery — and the provider's
            // cooldown budget belongs to those resolutions, so Test All can
            // neither rotate nor report a throttle.
            guard let resolved = currentResolvedURL(for: entry) else {
                return .deferred(
                    reason: "no resolved proxy yet — this entry resolves at the next launch or connection",
                    retryAfter: 60
                )
            }
            let health = await checkProxy(resolved)
            return health.ok ? .ok(health) : .failed(health)
        }
        let health = await checkProxy(entry.url)
        return health.ok ? .ok(health) : .failed(health)
    }

    /// The URL an entry is currently serving: the live upstream when the entry
    /// is routed, the pinned upstream when a pinned listener holds one, and
    /// otherwise the resolution its script cache holds.
    private func currentResolvedURL(for entry: ProxyEntry) -> String? {
        Self.resolvedURL(
            entryID: entry.id,
            upstream: upstream,
            pinned: pinnedUpstreams[entry.id],
            cacheURL: proxyScriptCachedURL(for: entry.id)
        )
    }

    /// Pure choice rule behind `currentResolvedURL(for:)`.
    static func resolvedURL(
        entryID: String,
        upstream: EdgeUpstream?,
        pinned: EdgeUpstream?,
        cacheURL: String?
    ) -> String? {
        if let upstream, upstream.entryID == entryID { return upstream.url }
        if let pinned { return pinned.url }
        return cacheURL
    }

    // MARK: - Warm hop pool (upstream pre-dials)

    /// Pops a pre-dialed socket to the upstream proxy, if one is warm. The
    /// socket carries no application bytes, so a stale reuse can never leak
    /// anything between clients — a failure here is handled exactly like a
    /// failed cold dial by the caller's retry contract.
    func takeWarmProxySocket(for upstreamURL: String) -> EdgeSocket? {
        guard let key = EdgeHopPool.key(for: upstreamURL) else { return nil }
        var entries = hopPool[key] ?? []
        let now = Date().timeIntervalSince1970
        var chosen: EdgeSocket?
        while let candidate = entries.popLast() {
            if now - candidate.createdAt <= hopPoolLifetime, candidate.socket.isReadyForReuse {
                chosen = candidate.socket
                break
            }
            candidate.socket.cancel()
        }
        hopPool[key] = entries.isEmpty ? nil : entries
        return chosen
    }

    /// Starts warming one pooled socket for the current upstream, if the pool
    /// is below depth. Fire-and-forget: failures are silent (the next dial
    /// just pays the handshake). Seed only for the *current* upstream — a
    /// stale entry from a previous endpoint is drained on switch, not served.
    func warmProxySocket(for upstreamURL: String) {
        guard let key = EdgeHopPool.key(for: upstreamURL) else { return }
        let now = Date().timeIntervalSince1970
        var entries = hopPool[key] ?? []
        entries.removeAll { now - $0.createdAt > hopPoolLifetime }
        guard entries.count < hopPoolDepth else {
            hopPool[key] = entries
            return
        }
        hopPool[key] = entries
        guard let target = EdgeHopPool.dialTarget(for: upstreamURL) else { return }
        Task.detached(priority: .utility) { [weak self] in
            let socket = EdgeSocket(
                host: target.host, port: target.port, tls: target.tls,
                serverName: target.tls ? target.host : nil
            )
            do {
                try await socket.awaitReady(timeout: 5)
            } catch {
                socket.cancel()
                return
            }
            await self?.storeWarmSocket(socket, key: key)
        }
    }

    private func storeWarmSocket(_ socket: EdgeSocket, key: String) {
        let now = Date().timeIntervalSince1970
        var entries = hopPool[key] ?? []
        entries.removeAll { now - $0.createdAt > hopPoolLifetime }
        guard entries.count < hopPoolDepth,
              let current = upstream, EdgeHopPool.key(for: current.url) == key else {
            socket.cancel()
            return
        }
        entries.append((socket, now))
        hopPool[key] = entries
    }

    private func drainHopPool() {
        for entries in hopPool.values {
            for entry in entries { entry.socket.cancel() }
        }
        hopPool = [:]
    }

    // MARK: - Status

    func status() -> EdgeStatusResponse {
        let now = Date().timeIntervalSince1970
        let mode = loadState()?.mode ?? .off
        var tunnels: [EdgeStatusResponse.Tunnel] = []
        for record in tunnelsActive.values {
            tunnels.append(EdgeStatusResponse.Tunnel(
                clientPort: Int(record.clientPort),
                peerPid: record.peerPid,
                peerName: record.peerName,
                label: record.label,
                startedAt: record.startedAt,
                endedAt: nil,
                bytesUp: record.bytesUp,
                bytesDown: record.bytesDown,
                active: true
            ))
        }
        for record in tunnelsRecent {
            tunnels.append(EdgeStatusResponse.Tunnel(
                clientPort: Int(record.clientPort),
                peerPid: record.peerPid,
                peerName: record.peerName,
                label: record.label,
                startedAt: record.startedAt,
                endedAt: record.endedAt,
                bytesUp: record.bytesUp,
                bytesDown: record.bytesDown,
                active: false
            ))
        }
        tunnels.sort { $0.startedAt > $1.startedAt }
        if tunnels.count > 64 { tunnels = Array(tunnels.prefix(64)) }

        return EdgeStatusResponse(
            ok: true,
            protocolVersion: EdgeProtocol.version,
            pid: getpid(),
            port: config.port,
            mode: mode,
            upstream: upstream.map {
                EdgeStatusResponse.Upstream(
                    entryID: $0.entryID,
                    label: $0.label,
                    maskedURL: maskedProxyURL($0.url),
                    source: $0.source,
                    resolvedAt: $0.resolvedAt,
                    expiresAt: $0.expiresAt,
                    strikes: $0.strikes
                )
            },
            pendingReason: pendingReason,
            throttleRetryAt: throttleRetryAt.flatMap { $0 > now ? $0 : nil },
            lastErrors: lastErrors,
            counters: EdgeStatusResponse.Counters(
                resolutions: resolutions,
                switches: switches,
                dialFailures: dialFailures,
                streamFailures: streamFailures,
                directFallbacks: directFallbacks,
                tunnelsTotal: tunnelsTotal,
                tunnelsActive: tunnelsActive.count
            ),
            tunnels: tunnels,
            listeners: listenerReport?.snapshot().map {
                EdgeStatusResponse.Listener(port: $0.port, entryID: $0.entryID, activated: $0.activated)
            } ?? [],
            launchedAt: launchedAt
        )
    }
}
