@preconcurrency import Network
import Foundation
import RelayDockCore

/// Handles one client connection end to end: parse the head, route through
/// the policy, dial (with the retry-on-dial contract), hand back the tunnel,
/// and pump bytes until either side ends.
final class EdgeClientConnection: @unchecked Sendable {
    private let socket: EdgeSocket
    private let daemon: EdgeDaemon
    /// The actual loopback port this connection arrived on. Tunnel attribution
    /// and free-usage reports must use the listener's port, not the primary
    /// `edge.json` port a pinned server also carries.
    let edgePort: UInt16
    private let log: EdgeLog
    private let clientPort: UInt16?
    /// Non-nil when this connection arrived on a listener pinned to one
    /// entry (per-account ports).
    private let pinnedEntryID: String?

    init(
        socket: EdgeSocket,
        peerPort: UInt16?,
        daemon: EdgeDaemon,
        edgePort: UInt16,
        log: EdgeLog,
        pinnedEntryID: String? = nil
    ) {
        self.socket = socket
        self.daemon = daemon
        self.edgePort = edgePort
        self.log = log
        self.clientPort = peerPort
        self.pinnedEntryID = pinnedEntryID
    }

    func start() {
        Task { await run() }
    }

    private func run() async {
        do {
            try await handle()
        } catch {
            log.warn("connection: \(error.localizedDescription)")
        }
        socket.cancel()
    }

    private func handle() async throws {
        let (head, rest, complete) = try await socket.receiveUntilHead()
        if complete && head.isEmpty { return }
        guard let request = EdgeHTTPRequest.parse(head: head) else {
            try await sendSimple(
                status: 400, reason: "Bad Request",
                body: "RelayDock Edge could not parse the request head."
            )
            return
        }
        switch request.kind {
        case .invalid(let reason):
            try await sendSimple(status: 400, reason: "Bad Request", body: reason)
        case .admin:
            try await handleAdmin(request)
        case .connect(let host, let port):
            try await handleConnect(request, host: host, port: port, clientPrelude: rest)
        case .forward(_, let scheme, let host, let port, _):
            try await handleForward(request, scheme: scheme, host: host, port: port, clientPrelude: rest)
        }
    }

    // MARK: - Admin API

    private func handleAdmin(_ request: EdgeHTTPRequest) async throws {
        guard case .admin(let method, let path, let query) = request.kind else { return }
        switch (method, path) {
        case ("GET", "/__relaydock/status"):
            let status = await daemon.status()
            try await sendJSON(status)
        case ("GET", "/__relaydock/check"), ("POST", "/__relaydock/check"):
            let scope: EdgeCheckScope
            if query["scope"] == "all" {
                scope = .all
            } else if let entryID = query["entry"], !entryID.isEmpty {
                scope = .entries([entryID])
            } else {
                scope = .active
            }
            let outcomes = await daemon.runChecks(scope: scope)
            try await sendJSON(EdgeCheckResponse(outcomes: outcomes))
        case ("POST", "/__relaydock/free-usage-limit"):
            guard let rawRetryAfterMs = query["retryAfterMs"],
                  let retryAfterMs = Double(rawRetryAfterMs) else {
                try await sendSimple(status: 400, reason: "Bad Request", body: "retryAfterMs is required.")
                return
            }
            let result = await daemon.reportFreeUsageLimit(
                retryAfterMs: retryAfterMs,
                reportClientPort: clientPort,
                edgePort: edgePort,
                explicitEntryID: query["entryID"]
            )
            switch result {
            case .flagged(let entryID, _):
                try await sendSimple(status: 200, reason: "OK", body: "Proxy \(entryID) paused until reset.")
            case .unmatched:
                try await sendSimple(
                    status: 409, reason: "Conflict",
                    body: "No matching proxy entry or recent OpenCode tunnel could be matched to this report."
                )
            case .invalidCooldown:
                try await sendSimple(status: 400, reason: "Bad Request", body: "retryAfterMs is outside the supported range.")
            case .persistenceFailed:
                try await sendSimple(status: 500, reason: "Internal Server Error", body: "Could not persist the proxy cooldown.")
            }
        case ("POST", "/__relaydock/shutdown"):
            try await sendJSON(["ok": true])
            log.info("shutdown requested through the admin API")
            Task {
                try? await Task.sleep(nanoseconds: 150_000_000)
                exit(0)
            }
        default:
            try await sendSimple(status: 404, reason: "Not Found", body: "Unknown RelayDock endpoint.")
        }
    }

    // MARK: - CONNECT

    private func handleConnect(
        _ request: EdgeHTTPRequest,
        host: String,
        port: UInt16,
        clientPrelude: Data
    ) async throws {
        let decision = await daemon.decideRoute(pinning: pinnedEntryID)
        switch decision {
        case .direct:
            do {
                let tunnel = try await EdgeDialer.openDirect(toHost: host, port: port)
                try await sendConnectEstablished()
                try await relay(to: tunnel, clientPrelude: clientPrelude, upstreamEntryID: nil, label: nil)
            } catch {
                try await sendSimple(
                    status: 502, reason: "Bad Gateway",
                    body: "RelayDock Edge: direct connection to \(host):\(port) failed (\(error.localizedDescription))."
                )
            }
        case .upstream(let first):
            let warm = await daemon.takeWarmProxySocket(for: first.url)
            let dialed = await withDialRetry(first, pinnedEntryID: pinnedEntryID, warmSocket: warm) { upstream, reusing in
                try await EdgeDialer.openTunnel(
                    through: upstream.url, toHost: host, port: port, reusing: reusing
                )
            }
            if let dialed {
                await daemon.warmProxySocket(for: dialed.upstream.url)
                try await sendConnectEstablished()
                try await relay(
                    to: dialed.tunnel,
                    clientPrelude: clientPrelude,
                    upstreamEntryID: dialed.upstream.entryID,
                    label: dialed.upstream.label
                )
            } else {
                let reason = await daemon.refusalReason(pinning: pinnedEntryID) ?? "no usable upstream resolved"
                if pinnedEntryID == nil, await daemon.directFallbackEnabled() {
                    try await serveDirectFallback(reason: reason, host: host, port: port, clientPrelude: clientPrelude)
                } else {
                    let retryAfter = await daemon.refusalRetryAfter()
                    try await sendSimple(
                        status: 502, reason: "Bad Gateway",
                        body: "RelayDock Edge: \(reason)",
                        extraHeaders: Self.retryAfterHeaders(retryAfter)
                    )
                }
            }
        case .directFallback(let reason):
            try await serveDirectFallback(reason: reason, host: host, port: port, clientPrelude: clientPrelude)
        case .refuse(let reason, let retryAt):
            try await sendSimple(
                status: 502, reason: "Bad Gateway",
                body: "RelayDock Edge: \(reason)",
                extraHeaders: Self.retryAfterHeaders(retryAt.map { $0 - Date().timeIntervalSince1970 })
            )
        }
    }

    // MARK: - Absolute-form forwarding (plain HTTP through the proxy)

    private func handleForward(
        _ request: EdgeHTTPRequest,
        scheme: String,
        host: String,
        port: UInt16,
        clientPrelude: Data
    ) async throws {
        let decision = await daemon.decideRoute(pinning: pinnedEntryID)
        switch decision {
        case .direct:
            do {
                let tunnel = try await EdgeDialer.openDirect(toHost: host, port: port)
                let head = request.originForwardHead(upstreamAuthorization: nil)
                try await tunnel.socket.send(head)
                if !clientPrelude.isEmpty { try await tunnel.socket.send(clientPrelude) }
                try await relay(to: tunnel, clientPrelude: Data(), upstreamEntryID: nil, label: nil)
            } catch {
                try await sendSimple(
                    status: 502, reason: "Bad Gateway",
                    body: "RelayDock Edge: direct connection to \(host):\(port) failed (\(error.localizedDescription))."
                )
            }
        case .upstream(let first):
            // Only SOCKS tunnels may reuse a warm socket on the forward path:
            // they handshake first, so a stale pooled socket surfaces as a
            // dial failure the retry contract can act on. A plain http/https
            // hop has no handshake — a stale reuse would break mid-request.
            let warm: EdgeSocket?
            switch EdgeDialer.scheme(of: first.url) {
            case "socks5", "socks5h", "socks4", "socks4a":
                warm = await daemon.takeWarmProxySocket(for: first.url)
            default:
                warm = nil
            }
            let dialed = await withDialRetry(first, pinnedEntryID: pinnedEntryID, warmSocket: warm) { upstream, reusing in
                try await self.openForwardTunnel(
                    through: upstream, request: request, host: host, port: port,
                    clientPrelude: clientPrelude, reusing: reusing
                )
            }
            if let dialed {
                await daemon.warmProxySocket(for: dialed.upstream.url)
                try await relay(
                    to: dialed.tunnel,
                    clientPrelude: Data(),
                    upstreamEntryID: dialed.upstream.entryID,
                    label: dialed.upstream.label,
                    requestSent: true
                )
            } else {
                let reason = await daemon.refusalReason(pinning: pinnedEntryID) ?? "no usable upstream resolved"
                if pinnedEntryID == nil, await daemon.directFallbackEnabled() {
                    try await serveForwardFallback(
                        reason: reason, request: request, host: host, port: port, clientPrelude: clientPrelude
                    )
                } else {
                    let retryAfter = await daemon.refusalRetryAfter()
                    try await sendSimple(
                        status: 502, reason: "Bad Gateway",
                        body: "RelayDock Edge: \(reason)",
                        extraHeaders: Self.retryAfterHeaders(retryAfter)
                    )
                }
            }
        case .directFallback(let reason):
            try await serveForwardFallback(
                reason: reason, request: request, host: host, port: port, clientPrelude: clientPrelude
            )
        case .refuse(let reason, let retryAt):
            try await sendSimple(
                status: 502, reason: "Bad Gateway",
                body: "RelayDock Edge: \(reason)",
                extraHeaders: Self.retryAfterHeaders(retryAt.map { $0 - Date().timeIntervalSince1970 })
            )
        }
    }

    /// Dials and primes the far end for one forwarded HTTP request. The head
    /// and any buffered body bytes are sent here (inside the retry) so a
    /// failed attempt never leaves half a request on the wire that counts.
    private func openForwardTunnel(
        through upstream: EdgeUpstream,
        request: EdgeHTTPRequest,
        host: String,
        port: UInt16,
        clientPrelude: Data,
        reusing warm: EdgeSocket? = nil
    ) async throws -> EdgeUpstreamTunnel {
        switch EdgeDialer.scheme(of: upstream.url) {
        case "socks5", "socks5h", "socks4", "socks4a":
            let tunnel = try await EdgeDialer.openTunnel(through: upstream.url, toHost: host, port: port, reusing: warm)
            try await tunnel.socket.send(request.originForwardHead(upstreamAuthorization: nil))
            if !clientPrelude.isEmpty { try await tunnel.socket.send(clientPrelude) }
            return tunnel
        default:
            // No handshake on a plain proxy hop: a pooled socket could only
            // fail mid-request, so http/https forwards always dial cold.
            warm?.cancel()
            let hop = try await EdgeDialer.openProxySocket(through: upstream.url)
            let authorization = hop.credentials.map { EdgeSocks.basicAuthorization($0) }
            try await hop.socket.send(request.absoluteForwardHead(upstreamAuthorization: authorization))
            if !clientPrelude.isEmpty { try await hop.socket.send(clientPrelude) }
            return EdgeUpstreamTunnel(socket: hop.socket, initialData: Data())
        }
    }

    // MARK: - Direct fallback (opt-in)

    /// Opt-in direct fallback for CONNECT: the policy found no usable
    /// upstream (`reason`) and the pool explicitly allows direct. The tunnel
    /// carries the fallback label so Edge's accounting can never present it
    /// as proxied; a failed direct dial still lands as the usual 502.
    private func serveDirectFallback(reason: String, host: String, port: UInt16, clientPrelude: Data) async throws {
        do {
            let tunnel = try await EdgeDialer.openDirect(toHost: host, port: port)
            await daemon.noteDirectFallback(reason: reason)
            try await sendConnectEstablished()
            try await relay(
                to: tunnel,
                clientPrelude: clientPrelude,
                upstreamEntryID: nil,
                label: Self.directFallbackLabel
            )
        } catch {
            try await sendSimple(
                status: 502, reason: "Bad Gateway",
                body: "RelayDock Edge: direct fallback to \(host):\(port) failed (\(error.localizedDescription)); \(reason)"
            )
        }
    }

    /// Opt-in direct fallback for forwarded HTTP: dials direct and primes the
    /// far end with the origin-form head inside the same attempt, so a failed
    /// fallback never leaves half a request on the wire.
    private func serveForwardFallback(
        reason: String,
        request: EdgeHTTPRequest,
        host: String,
        port: UInt16,
        clientPrelude: Data
    ) async throws {
        do {
            let tunnel = try await EdgeDialer.openDirect(toHost: host, port: port)
            await daemon.noteDirectFallback(reason: reason)
            try await tunnel.socket.send(request.originForwardHead(upstreamAuthorization: nil))
            if !clientPrelude.isEmpty { try await tunnel.socket.send(clientPrelude) }
            try await relay(
                to: tunnel,
                clientPrelude: Data(),
                upstreamEntryID: nil,
                label: Self.directFallbackLabel,
                requestSent: true
            )
        } catch {
            try await sendSimple(
                status: 502, reason: "Bad Gateway",
                body: "RelayDock Edge: direct fallback to \(host):\(port) failed (\(error.localizedDescription)); \(reason)"
            )
        }
    }

    /// The tunnel label every direct-fallback relay carries.
    static let directFallbackLabel = "direct (fallback)"

    // MARK: - Dial + retry contract

    private struct DialedTunnel {
        let tunnel: EdgeUpstreamTunnel
        let upstream: EdgeUpstream
    }

    /// One internal retry on dial failure. Auto retries through the next
    /// eligible entry; Manual re-resolves its selected entry, and a pinned
    /// listener retries only within its own entry. A warm socket is offered
    /// to the first attempt only — a stale pooled socket can never be reused.
    private func withDialRetry(
        _ upstream: EdgeUpstream,
        pinnedEntryID: String? = nil,
        warmSocket: EdgeSocket? = nil,
        operation: (EdgeUpstream, EdgeSocket?) async throws -> EdgeUpstreamTunnel
    ) async -> DialedTunnel? {
        do {
            let tunnel = try await operation(upstream, warmSocket)
            if let pinnedEntryID {
                await daemon.notePinnedSuccess(entryID: pinnedEntryID)
            } else {
                await daemon.noteUpstreamSuccess(entryID: upstream.entryID)
            }
            return DialedTunnel(tunnel: tunnel, upstream: upstream)
        } catch {
            log.warn("dial failed via \(upstream.label): \(error.localizedDescription)")
            if let pinnedEntryID {
                guard await daemon.notePinnedDialFailure(entryID: pinnedEntryID) else { return nil }
                guard case .upstream(let replacement) = await daemon.decideRoute(pinning: pinnedEntryID) else {
                    return nil
                }
                do {
                    let tunnel = try await operation(replacement, nil)
                    await daemon.notePinnedSuccess(entryID: pinnedEntryID)
                    return DialedTunnel(tunnel: tunnel, upstream: replacement)
                } catch {
                    log.warn("pinned retry failed via \(replacement.label): \(error.localizedDescription)")
                    _ = await daemon.notePinnedDialFailure(entryID: pinnedEntryID)
                    return nil
                }
            }
            guard let replacement = await daemon.noteDialFailure(for: upstream, reResolve: true) else { return nil }
            do {
                let tunnel = try await operation(replacement, nil)
                await daemon.noteUpstreamSuccess(entryID: replacement.entryID)
                return DialedTunnel(tunnel: tunnel, upstream: replacement)
            } catch {
                log.warn("retry dial failed via \(replacement.label): \(error.localizedDescription)")
                _ = await daemon.noteDialFailure(for: replacement, reResolve: false)
                return nil
            }
        }
    }

    // MARK: - Relay

    private func relay(
        to tunnel: EdgeUpstreamTunnel,
        clientPrelude: Data,
        upstreamEntryID: String?,
        label: String?,
        requestSent: Bool = false
    ) async throws {
        await daemon.registerTunnel(
            clientPort: clientPort,
            edgePort: edgePort,
            entryID: upstreamEntryID,
            label: label
        )
        let startedAt = Date().timeIntervalSince1970
        let end = EdgeRelayEndHolder()
        let counts = await withTaskGroup(
            of: (up: Int, down: Int).self,
            returning: (up: Int, down: Int).self
        ) { group in
            group.addTask {
                // Client -> upstream.
                var up = 0
                if !clientPrelude.isEmpty {
                    do {
                        try await tunnel.socket.send(clientPrelude)
                        up += clientPrelude.count
                    } catch {
                        end.record(.upstreamDied)
                    }
                }
                if end.value == nil {
                    while true {
                        let step: (data: Data, isComplete: Bool)
                        do {
                            step = try await self.socket.receiveSome()
                        } catch {
                            end.record(.clientClosed)
                            break
                        }
                        if !step.data.isEmpty {
                            do {
                                try await tunnel.socket.send(step.data)
                                up += step.data.count
                            } catch {
                                end.record(.upstreamDied)
                                break
                            }
                        }
                        if step.isComplete {
                            end.record(.clientClosed)
                            break
                        }
                    }
                }
                tunnel.socket.cancel()
                return (up, 0)
            }
            group.addTask {
                // Upstream -> client.
                var down = 0
                if !tunnel.initialData.isEmpty {
                    do {
                        try await self.socket.send(tunnel.initialData)
                        down += tunnel.initialData.count
                    } catch {
                        end.record(.clientClosed)
                    }
                }
                if end.value == nil {
                    while true {
                        let step: (data: Data, isComplete: Bool)
                        do {
                            step = try await tunnel.socket.receiveSome()
                        } catch {
                            end.record(.upstreamDied)
                            break
                        }
                        if !step.data.isEmpty {
                            do {
                                try await self.socket.send(step.data)
                                down += step.data.count
                            } catch {
                                end.record(.clientClosed)
                                break
                            }
                        }
                        if step.isComplete {
                            end.record(.upstreamClosed)
                            break
                        }
                    }
                }
                self.socket.cancel()
                return (0, down)
            }
            var total = (up: 0, down: 0)
            for await part in group {
                total.up += part.up
                total.down += part.down
            }
            return total
        }
        await daemon.finishTunnel(clientPort: clientPort, bytesUp: counts.up, bytesDown: counts.down)
        guard let upstreamEntryID else { return }
        let duration = Date().timeIntervalSince1970 - startedAt
        switch EdgeRelayPolicy.verdict(
            end: end.value ?? .clientClosed,
            requestSent: requestSent,
            bytesUp: counts.up,
            bytesDown: counts.down,
            duration: duration
        ) {
        case .clean:
            break
        case .died:
            await daemon.noteTunnelFailure(entryID: upstreamEntryID, failure: .died)
        case .stalled(let stallDuration):
            await daemon.noteTunnelFailure(entryID: upstreamEntryID, failure: .stalled(duration: stallDuration))
        }
    }

    // MARK: - Responses

    private func sendConnectEstablished() async throws {
        try await socket.send(Data("HTTP/1.1 200 Connection Established\r\n\r\n".utf8))
    }

    private func sendJSON<T: Encodable>(_ value: T) async throws {
        let payload = try JSONEncoder().encode(value)
        var response = Data(
            "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(payload.count)\r\nConnection: close\r\n\r\n".utf8
        )
        response.append(payload)
        try await socket.send(response)
    }

    /// `Retry-After: <seconds>` for a 502 whose cause carries a known
    /// cooldown. Integer seconds per RFC 9110; sub-second waits round up.
    static func retryAfterHeaders(_ seconds: TimeInterval?) -> [String] {
        guard let seconds, seconds > 0 else { return [] }
        return ["Retry-After: \(max(1, Int(seconds.rounded(.up))))"]
    }

    private func sendSimple(
        status: Int,
        reason: String,
        body: String,
        extraHeaders: [String] = []
    ) async throws {
        let payload = Data(body.utf8)
        var head = "HTTP/1.1 \(status) \(reason)\r\n"
        head += "Content-Type: text/plain; charset=utf-8\r\n"
        head += "Content-Length: \(payload.count)\r\n"
        head += "Connection: close\r\n"
        for header in extraHeaders { head += header + "\r\n" }
        head += "\r\n"
        var response = Data(head.utf8)
        response.append(payload)
        try await socket.send(response)
    }
}

// MARK: - Relay outcome policy

/// Which side ended a relay session first. Recorded once per session so an
/// induced error from the peer's cancellation is never mistaken for a fresh
/// upstream problem.
enum EdgeRelayEnd: Equatable, Sendable {
    /// The client closed or errored out first.
    case clientClosed
    /// The upstream closed the tunnel cleanly.
    case upstreamClosed
    /// The upstream socket errored mid-session.
    case upstreamDied
}

/// What a finished relay session says about the upstream.
enum EdgeRelayVerdict: Equatable, Sendable {
    case clean
    case died
    case stalled(duration: TimeInterval)
}

enum EdgeRelayPolicy {
    /// A tunnel that moved request bytes but never received a single
    /// response byte for this long was not doing useful work: the client
    /// almost certainly gave up on a zombie endpoint. TLS alone would have
    /// produced response bytes, so silence this long is a strong signal.
    static let stallThreshold: TimeInterval = 30

    static func verdict(
        end: EdgeRelayEnd,
        requestSent: Bool,
        bytesUp: Int,
        bytesDown: Int,
        duration: TimeInterval
    ) -> EdgeRelayVerdict {
        if end == .upstreamDied { return .died }
        if bytesDown == 0, requestSent || bytesUp > 0, duration >= stallThreshold {
            return .stalled(duration: duration)
        }
        return .clean
    }
}

/// First-wins latch for the relay's end classification.
private final class EdgeRelayEndHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: EdgeRelayEnd?

    func record(_ value: EdgeRelayEnd) {
        lock.lock()
        if stored == nil { stored = value }
        lock.unlock()
    }

    var value: EdgeRelayEnd? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

/// Maps the daemon's check outcomes into the shared wire shape (`EdgeCheckResponse`
/// lives in Core so the app can decode what Edge sends here).
extension EdgeCheckResponse {
    init(outcomes: [String: EdgeCheckOutcome]) {
        var mapped: [String: Result] = [:]
        for (id, outcome) in outcomes {
            switch outcome {
            case .ok(let health), .failed(let health):
                mapped[id] = Result(
                    ok: health.ok,
                    latencyMs: health.latencyMs,
                    checkedAt: health.checkedAt,
                    error: health.error,
                    deferred: false,
                    retryAfter: nil
                )
            case .deferred(let reason, let retryAfter):
                mapped[id] = Result(
                    ok: false,
                    latencyMs: nil,
                    checkedAt: Date().timeIntervalSince1970 * 1000,
                    error: reason,
                    deferred: true,
                    retryAfter: retryAfter
                )
            }
        }
        self.init(results: mapped)
    }
}
