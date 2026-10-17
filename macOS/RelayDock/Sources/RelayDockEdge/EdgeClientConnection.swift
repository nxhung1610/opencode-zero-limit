@preconcurrency import Network
import Foundation
import RelayDockCore

/// Handles one client connection end to end: parse the head, gate on the
/// token, route through the policy, dial (with the retry-on-dial contract),
/// hand back the tunnel, and pump bytes until either side ends.
final class EdgeClientConnection: @unchecked Sendable {
    private let socket: EdgeSocket
    private let daemon: EdgeDaemon
    private let config: EdgeConfigFile
    private let log: EdgeLog
    private let clientPort: UInt16?

    init(connection: NWConnection, daemon: EdgeDaemon, config: EdgeConfigFile, log: EdgeLog) {
        let socket = EdgeSocket(connection: connection, label: "relaydock.edge.client")
        self.socket = socket
        self.daemon = daemon
        self.config = config
        self.log = log
        self.clientPort = socket.remotePort
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
        guard EdgeAuth.isAuthorized(headers: request.headers, token: config.token) else {
            try await sendSimple(
                status: 401, reason: "Unauthorized",
                body: "Missing or invalid RelayDock edge token.",
                extraHeaders: ["WWW-Authenticate: Bearer realm=\"relaydock\""]
            )
            return
        }
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
        guard EdgeAuth.isAuthorized(headers: request.headers, token: config.token) else {
            try await sendSimple(
                status: 407, reason: "Proxy Authentication Required",
                body: "RelayDock Edge requires its token (relaunch the wrapped command).",
                extraHeaders: ["Proxy-Authenticate: Basic realm=\"relaydock\""]
            )
            return
        }

        let decision = await daemon.decideRoute()
        switch decision {
        case .direct:
            do {
                let tunnel = try await EdgeDialer.openDirect(toHost: host, port: port)
                try await sendConnectEstablished()
                try await relay(to: tunnel, clientPrelude: clientPrelude, label: nil)
            } catch {
                try await sendSimple(
                    status: 502, reason: "Bad Gateway",
                    body: "RelayDock Edge: direct connection to \(host):\(port) failed (\(error.localizedDescription))."
                )
            }
        case .upstream(let first):
            let dialed = await withDialRetry(first) { upstream in
                try await EdgeDialer.openTunnel(through: upstream.url, toHost: host, port: port)
            }
            if let dialed {
                try await sendConnectEstablished()
                try await relay(to: dialed.tunnel, clientPrelude: clientPrelude, label: dialed.upstream.label)
            } else {
                let reason = await daemon.refusalReason() ?? "no usable upstream resolved"
                try await sendSimple(status: 502, reason: "Bad Gateway", body: "RelayDock Edge: \(reason)")
            }
        case .refuse(let reason, _):
            try await sendSimple(status: 502, reason: "Bad Gateway", body: "RelayDock Edge: \(reason)")
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
        guard EdgeAuth.isAuthorized(headers: request.headers, token: config.token) else {
            try await sendSimple(
                status: 407, reason: "Proxy Authentication Required",
                body: "RelayDock Edge requires its token (relaunch the wrapped command).",
                extraHeaders: ["Proxy-Authenticate: Basic realm=\"relaydock\""]
            )
            return
        }

        let decision = await daemon.decideRoute()
        switch decision {
        case .direct:
            do {
                let tunnel = try await EdgeDialer.openDirect(toHost: host, port: port)
                let head = request.originForwardHead(upstreamAuthorization: nil)
                try await tunnel.socket.send(head)
                if !clientPrelude.isEmpty { try await tunnel.socket.send(clientPrelude) }
                try await relay(to: tunnel, clientPrelude: Data(), label: nil)
            } catch {
                try await sendSimple(
                    status: 502, reason: "Bad Gateway",
                    body: "RelayDock Edge: direct connection to \(host):\(port) failed (\(error.localizedDescription))."
                )
            }
        case .upstream(let first):
            let dialed = await withDialRetry(first) { upstream in
                try await self.openForwardTunnel(
                    through: upstream, request: request, host: host, port: port, clientPrelude: clientPrelude
                )
            }
            if let dialed {
                try await relay(to: dialed.tunnel, clientPrelude: Data(), label: dialed.upstream.label)
            } else {
                let reason = await daemon.refusalReason() ?? "no usable upstream resolved"
                try await sendSimple(status: 502, reason: "Bad Gateway", body: "RelayDock Edge: \(reason)")
            }
        case .refuse(let reason, _):
            try await sendSimple(status: 502, reason: "Bad Gateway", body: "RelayDock Edge: \(reason)")
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
        clientPrelude: Data
    ) async throws -> EdgeUpstreamTunnel {
        switch EdgeDialer.scheme(of: upstream.url) {
        case "socks5", "socks5h", "socks4", "socks4a":
            let tunnel = try await EdgeDialer.openTunnel(through: upstream.url, toHost: host, port: port)
            try await tunnel.socket.send(request.originForwardHead(upstreamAuthorization: nil))
            if !clientPrelude.isEmpty { try await tunnel.socket.send(clientPrelude) }
            return tunnel
        default:
            let hop = try await EdgeDialer.openProxySocket(through: upstream.url)
            let authorization = hop.credentials.map { EdgeSocks.basicAuthorization($0) }
            try await hop.socket.send(request.absoluteForwardHead(upstreamAuthorization: authorization))
            if !clientPrelude.isEmpty { try await hop.socket.send(clientPrelude) }
            return EdgeUpstreamTunnel(socket: hop.socket, initialData: Data())
        }
    }

    // MARK: - Dial + retry contract

    private struct DialedTunnel {
        let tunnel: EdgeUpstreamTunnel
        let upstream: EdgeUpstream
    }

    /// One internal retry on dial failure: single-flight resolve, then retry
    /// with the replacement upstream, the old one while strikes are low, or
    /// give up. The client only ever sees the outcome.
    private func withDialRetry(
        _ upstream: EdgeUpstream,
        operation: (EdgeUpstream) async throws -> EdgeUpstreamTunnel
    ) async -> DialedTunnel? {
        do {
            let tunnel = try await operation(upstream)
            await daemon.noteUpstreamSuccess()
            return DialedTunnel(tunnel: tunnel, upstream: upstream)
        } catch {
            log.warn("dial failed via \(upstream.label): \(error.localizedDescription)")
            guard let replacement = await daemon.noteDialFailure(reResolve: true) else { return nil }
            do {
                let tunnel = try await operation(replacement)
                await daemon.noteUpstreamSuccess()
                return DialedTunnel(tunnel: tunnel, upstream: replacement)
            } catch {
                log.warn("retry dial failed via \(replacement.label): \(error.localizedDescription)")
                _ = await daemon.noteDialFailure(reResolve: false)
                return nil
            }
        }
    }

    // MARK: - Relay

    private func relay(to tunnel: EdgeUpstreamTunnel, clientPrelude: Data, label: String?) async throws {
        await daemon.registerTunnel(
            clientPort: clientPort,
            edgePort: UInt16(truncatingIfNeeded: config.port),
            label: label
        )
        let counts = await withTaskGroup(
            of: (up: Int, down: Int).self,
            returning: (up: Int, down: Int).self
        ) { group in
            group.addTask {
                // Client -> upstream.
                var up = 0
                do {
                    if !clientPrelude.isEmpty {
                        try await tunnel.socket.send(clientPrelude)
                        up += clientPrelude.count
                    }
                    while true {
                        let (data, isComplete) = try await self.socket.receiveSome()
                        if !data.isEmpty {
                            try await tunnel.socket.send(data)
                            up += data.count
                        }
                        if isComplete { break }
                    }
                } catch {
                    // Either side ended or errored; the other direction is
                    // cancelled below so both pump tasks finish.
                }
                tunnel.socket.cancel()
                return (up, 0)
            }
            group.addTask {
                // Upstream -> client.
                var down = 0
                do {
                    if !tunnel.initialData.isEmpty {
                        try await self.socket.send(tunnel.initialData)
                        down += tunnel.initialData.count
                    }
                    while true {
                        let (data, isComplete) = try await tunnel.socket.receiveSome()
                        if !data.isEmpty {
                            try await self.socket.send(data)
                            down += data.count
                        }
                        if isComplete { break }
                    }
                } catch {
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

/// The `/__relaydock/check` response shape.
struct EdgeCheckResponse: Codable {
    struct Result: Codable {
        var ok: Bool
        var latencyMs: Double?
        var checkedAt: Double
        var error: String?
        var deferred: Bool
        var retryAfter: Double?
    }

    var results: [String: Result]

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
        results = mapped
    }
}
