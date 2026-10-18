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
    private var stateEverLoaded = false
    private var bindings: [String: String] = [:]
    private var upstream: EdgeUpstream?
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
    private var tunnelsTotal = 0
    private var lastDialFailureAt: Double = 0
    private var tunnelsActive: [UInt16: TunnelRecord] = [:]
    private var tunnelsRecent: [TunnelRecord] = []
    private var nextCheckAt: [String: Double] = [:]
    private var failureStreak: [String: Int] = [:]
    private var schedulerTask: Task<Void, Never>?

    init(config: EdgeConfigFile, directory: URL, log: EdgeLog) {
        self.config = config
        self.directory = directory
        self.log = log
    }

    // MARK: - State file

    private var stateURL: URL { directory.appending(path: "proxies.json") }

    /// Reads `proxies.json` with an mtime cache. A damaged file keeps the
    /// last good configuration and never breaks live traffic; only a file
    /// that was never readable at all returns nil (callers then refuse).
    private func loadState() -> ProxyState? {
        let url = stateURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            stateEverLoaded = true
            cachedState = .defaults
            cachedStateMtime = nil
            return .defaults
        }
        let mtime = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        if let cachedState, let mtime, mtime == cachedStateMtime { return cachedState }
        guard let data = try? Data(contentsOf: url),
              let state = try? JSONDecoder().decode(ProxyState.self, from: data) else {
            log.warn("proxies.json is unreadable; keeping the last good configuration")
            return stateEverLoaded ? cachedState : nil
        }
        if !stateEverLoaded { bindings = state.bindings }
        stateEverLoaded = true
        cachedState = state
        cachedStateMtime = mtime
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
        for id in editedIDs {
            removeProxyScriptCacheSnapshot(for: id)
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

    private static func defaultRefusal(_ state: ProxyState) -> String {
        state.mode == .manual ? "no usable proxy is selected" : "no proxy in the pool is usable"
    }

    // MARK: - Routing

    func decideRoute() async -> EdgeRouteDecision {
        let now = Date().timeIntervalSince1970
        guard let state = loadState() else {
            return .refuse(reason: "proxies.json could not be read on this Mac", retryAt: nil)
        }
        if state.mode == .off { return .direct }
        if needsResolve(state: state, now: now) {
            if let outcome = await resolveLocked(state: state),
               case .success(let resolved, _) = outcome.kind {
                return .upstream(resolved)
            }
        }
        if let upstream { return .upstream(upstream) }
        if let retryAt = throttleRetryAt, retryAt > now {
            return .refuse(reason: pendingReason ?? "the provider is cooling down", retryAt: retryAt)
        }
        return .refuse(reason: pendingReason ?? Self.defaultRefusal(state), retryAt: nil)
    }

    func refusalReason() -> String? { pendingReason }

    /// Seconds a refused client should wait before retrying, while the
    /// policy sits inside a timed provider cooldown. Nil when no timed wait
    /// applies — the absence of the header means "retry whenever".
    func refusalRetryAfter() -> TimeInterval? {
        let now = Date().timeIntervalSince1970
        guard let retryAt = throttleRetryAt, retryAt > now else { return nil }
        return retryAt - now
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

    /// A dial through the current upstream failed. With `reResolve` the
    /// endpoint's cached snapshot is dropped, a single-flight resolve runs,
    /// and the caller gets the upstream to retry once: the replacement, the
    /// old one while strikes are low (a transient failure), or nil to give up.
    func noteDialFailure(reResolve: Bool) async -> EdgeUpstream? {
        dialFailures += 1
        let now = Date().timeIntervalSince1970
        let windowOpen = now - lastDialFailureAt <= 30
        lastDialFailureAt = now
        if var current = upstream {
            current.strikes = windowOpen ? current.strikes + 1 : 1
            upstream = current
            if reResolve { removeProxyScriptCacheSnapshot(for: current.entryID) }
        }
        guard reResolve else { return nil }
        let strikes = upstream?.strikes ?? 0
        if let state = loadState(), state.mode != .off,
           let outcome = await resolveLocked(state: state) {
            switch outcome.kind {
            case .success(let resolved, _): return resolved
            case .throttled, .failed, .modeChanged: break
            }
        }
        if strikes >= 3 { return nil }
        return upstream
    }

    func noteUpstreamSuccess() {
        if var current = upstream, current.strikes > 0 {
            current.strikes = 0
            upstream = current
        }
    }

    /// An established upstream tunnel died mid-stream or stalled. The same
    /// policy signal as a failed dial — count it, drop the cached snapshot,
    /// re-resolve so the next connection leaves the bad endpoint — except
    /// this request can never be retried: bytes are already in flight. When
    /// a re-resolve already replaced the upstream (entryID no longer
    /// current), only the counter and the log record it.
    func noteTunnelFailure(entryID: String, failure: EdgeTunnelFailure) async {
        streamFailures += 1
        let label = upstream?.entryID == entryID ? (upstream?.label ?? entryID) : entryID
        pushError("tunnel failed via \(label): \(failure.summary)")
        log.warn("tunnel failed via \(label): \(failure.summary)")
        guard upstream?.entryID == entryID else { return }
        let now = Date().timeIntervalSince1970
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
        if let state = loadState(), state.mode != .off {
            _ = await resolveLocked(state: state)
        }
    }

    // MARK: - Tunnels

    func registerTunnel(clientPort: UInt16?, edgePort: UInt16, label: String?) {
        tunnelsTotal += 1
        guard let clientPort else { return }
        // Resolve the peer now: the client TCP connection is guaranteed to be
        // established at registration, while a lookup from `status()` may run
        // after the tunnel closed and can no longer be attributed.
        let peer = attribution.peer(forClientPort: clientPort, edgePort: edgePort)
        tunnelsActive[clientPort] = TunnelRecord(
            clientPort: clientPort,
            edgePort: edgePort,
            entryID: upstream?.entryID,
            label: label ?? upstream?.label,
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
            // Script errors and provider throttles say nothing about the
            // endpoint; they neither mark failed nor clear a failure streak.
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
        if let script = entry.script {
            do {
                let entryID = entry.id
                let resolved = try await Task.detached(priority: .utility) {
                    try ProxyScriptRunner.resolve(script, cacheID: entryID)
                }.value
                let health = await checkProxy(resolved)
                return health.ok ? .ok(health) : .failed(health)
            } catch {
                let message = error.localizedDescription
                if let retryAfter = proxyScriptRetryAfterSeconds(from: message) {
                    return .deferred(reason: message, retryAfter: retryAfter)
                }
                return .deferred(reason: message, retryAfter: 60)
            }
        }
        let health = await checkProxy(entry.url)
        return health.ok ? .ok(health) : .failed(health)
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
                tunnelsTotal: tunnelsTotal,
                tunnelsActive: tunnelsActive.count
            ),
            tunnels: tunnels,
            launchedAt: launchedAt
        )
    }
}
