import Foundation

/// The wire contract between RelayDock Edge and its consumers. Bump the
/// version whenever the status shape or admin API changes incompatibly; the
/// launcher only talks to a matching version, and Edge verifies a responding
/// instance before treating a port conflict as "already running".
public enum EdgeProtocol {
    public static let version = 1
}

/// The JSON shape of `GET /__relaydock/status`. Edge encodes it; the launcher
/// decodes it for the routing line; the app consumes it in P2.
public struct EdgeStatusResponse: Codable, Equatable, Sendable {
    public struct Upstream: Codable, Equatable, Sendable {
        public var entryID: String
        public var label: String
        /// Credentials are masked (`•••@host:port`).
        public var maskedURL: String
        /// `"script"` or `"static"`.
        public var source: String
        public var resolvedAt: Double
        public var expiresAt: Double?
        public var strikes: Int

        public init(
            entryID: String,
            label: String,
            maskedURL: String,
            source: String,
            resolvedAt: Double,
            expiresAt: Double? = nil,
            strikes: Int = 0
        ) {
            self.entryID = entryID
            self.label = label
            self.maskedURL = maskedURL
            self.source = source
            self.resolvedAt = resolvedAt
            self.expiresAt = expiresAt
            self.strikes = strikes
        }
    }

    public struct Counters: Codable, Equatable, Sendable {
        public var resolutions: Int
        public var switches: Int
        public var dialFailures: Int
        /// Established tunnels the upstream dropped mid-stream or left
        /// silent until the client gave up. Added after protocol 1 shipped;
        /// decoding tolerates its absence in older Edge binaries.
        public var streamFailures: Int
        /// Tunnels dialed directly by the pool's opt-in direct fallback —
        /// traffic that never went through a proxy. Added after protocol 1
        /// shipped; decoding tolerates its absence in older Edge binaries.
        public var directFallbacks: Int
        public var tunnelsTotal: Int
        public var tunnelsActive: Int

        public init(
            resolutions: Int = 0,
            switches: Int = 0,
            dialFailures: Int = 0,
            streamFailures: Int = 0,
            directFallbacks: Int = 0,
            tunnelsTotal: Int = 0,
            tunnelsActive: Int = 0
        ) {
            self.resolutions = resolutions
            self.switches = switches
            self.dialFailures = dialFailures
            self.streamFailures = streamFailures
            self.directFallbacks = directFallbacks
            self.tunnelsTotal = tunnelsTotal
            self.tunnelsActive = tunnelsActive
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            resolutions = try container.decode(Int.self, forKey: .resolutions)
            switches = try container.decode(Int.self, forKey: .switches)
            dialFailures = try container.decode(Int.self, forKey: .dialFailures)
            streamFailures = try container.decodeIfPresent(Int.self, forKey: .streamFailures) ?? 0
            directFallbacks = try container.decodeIfPresent(Int.self, forKey: .directFallbacks) ?? 0
            tunnelsTotal = try container.decode(Int.self, forKey: .tunnelsTotal)
            tunnelsActive = try container.decode(Int.self, forKey: .tunnelsActive)
        }
    }

    /// One tunnel Edge served, with best-effort same-user peer attribution.
    public struct Tunnel: Codable, Equatable, Sendable {
        public var clientPort: Int
        public var peerPid: Int32?
        public var peerName: String?
        public var label: String?
        public var startedAt: Double
        public var endedAt: Double?
        public var bytesUp: Int
        public var bytesDown: Int
        public var active: Bool

        public init(
            clientPort: Int,
            peerPid: Int32? = nil,
            peerName: String? = nil,
            label: String? = nil,
            startedAt: Double,
            endedAt: Double? = nil,
            bytesUp: Int = 0,
            bytesDown: Int = 0,
            active: Bool
        ) {
            self.clientPort = clientPort
            self.peerPid = peerPid
            self.peerName = peerName
            self.label = label
            self.startedAt = startedAt
            self.endedAt = endedAt
            self.bytesUp = bytesUp
            self.bytesDown = bytesDown
            self.active = active
        }
    }

    /// One loopback listener Edge opened, as reported at start. Added after
    /// protocol 1 shipped; decoding tolerates its absence in older binaries.
    public struct Listener: Codable, Equatable, Sendable {
        public var port: Int
        /// Entry this port is pinned to; nil for the primary listener.
        public var entryID: String?
        /// True when launchd provided the socket (socket activation).
        public var activated: Bool

        public init(port: Int, entryID: String? = nil, activated: Bool = false) {
            self.port = port
            self.entryID = entryID
            self.activated = activated
        }
    }

    public var ok: Bool
    public var protocolVersion: Int
    public var pid: Int32
    public var port: Int
    public var mode: ProxyMode
    public var upstream: Upstream?
    /// Why the last route decision failed or was deferred, if any.
    public var pendingReason: String?
    /// When a provider cooldown defers the next resolve attempt.
    public var throttleRetryAt: Double?
    public var lastErrors: [String]
    public var counters: Counters
    public var tunnels: [Tunnel]
    public var listeners: [Listener]
    public var launchedAt: Double

    public init(
        ok: Bool = true,
        protocolVersion: Int = EdgeProtocol.version,
        pid: Int32,
        port: Int,
        mode: ProxyMode,
        upstream: Upstream? = nil,
        pendingReason: String? = nil,
        throttleRetryAt: Double? = nil,
        lastErrors: [String] = [],
        counters: Counters = Counters(),
        tunnels: [Tunnel] = [],
        listeners: [Listener] = [],
        launchedAt: Double
    ) {
        self.ok = ok
        self.protocolVersion = protocolVersion
        self.pid = pid
        self.port = port
        self.mode = mode
        self.upstream = upstream
        self.pendingReason = pendingReason
        self.throttleRetryAt = throttleRetryAt
        self.lastErrors = lastErrors
        self.counters = counters
        self.tunnels = tunnels
        self.listeners = listeners
        self.launchedAt = launchedAt
    }

    /// Tolerant of keys added after protocol 1 shipped (`listeners`, and the
    /// counter set) so the launcher and the app can read status from older
    /// Edge binaries.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ok = try container.decode(Bool.self, forKey: .ok)
        protocolVersion = try container.decode(Int.self, forKey: .protocolVersion)
        pid = try container.decode(Int32.self, forKey: .pid)
        port = try container.decode(Int.self, forKey: .port)
        mode = try container.decode(ProxyMode.self, forKey: .mode)
        upstream = try container.decodeIfPresent(Upstream.self, forKey: .upstream)
        pendingReason = try container.decodeIfPresent(String.self, forKey: .pendingReason)
        throttleRetryAt = try container.decodeIfPresent(Double.self, forKey: .throttleRetryAt)
        lastErrors = try container.decodeIfPresent([String].self, forKey: .lastErrors) ?? []
        counters = try container.decodeIfPresent(Counters.self, forKey: .counters) ?? Counters()
        tunnels = try container.decodeIfPresent([Tunnel].self, forKey: .tunnels) ?? []
        listeners = try container.decodeIfPresent([Listener].self, forKey: .listeners) ?? []
        launchedAt = try container.decode(Double.self, forKey: .launchedAt)
    }
}

/// A synchronous client for Edge's admin endpoints. Used by the launcher
/// (routing line + ensure-running), the `relaydock-edge` CLI (`stop`,
/// `status`, single-instance check), and the app in P2.
public enum EdgeStatusClient {
    public static func fetchStatus(config: EdgeConfigFile, timeout: TimeInterval = 1.5) -> EdgeStatusResponse? {
        guard let url = URL(string: "http://127.0.0.1:\(config.port)/__relaydock/status") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
        return perform(request, timeout: timeout) { data in
            guard let status = try? JSONDecoder().decode(EdgeStatusResponse.self, from: data),
                  status.ok,
                  status.protocolVersion == EdgeProtocol.version else { return nil }
            return status
        }
    }

    /// True when an Edge acknowledged the shutdown request.
    public static func requestShutdown(config: EdgeConfigFile, timeout: TimeInterval = 1.5) -> Bool {
        guard let url = URL(string: "http://127.0.0.1:\(config.port)/__relaydock/shutdown") else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
        return perform(request, timeout: timeout) { _ in true } ?? false
    }

    private static func perform<T: Sendable>(
        _ request: URLRequest,
        timeout: TimeInterval,
        transform: @escaping @Sendable (Data) -> T?
    ) -> T? {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }

        let execution = SyncBox<T?>()
        let task = session.dataTask(with: request) { data, response, error in
            guard error == nil,
                  let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  let data else {
                execution.finish(nil)
                return
            }
            execution.finish(transform(data))
        }
        task.resume()
        _ = execution.wait(timeout: timeout + 0.5)
        task.cancel()
        guard let value = execution.value else { return nil }
        return value
    }

    // MARK: - Async admin calls (the app's status panel and delegated checks)

    /// The status fetch the app's panel polls. Async so SwiftUI surfaces can
    /// await it without blocking the main thread; the timeout stays short —
    /// the panel reads a miss as "Edge is not running", not as an error.
    public static func fetchStatusAsync(
        config: EdgeConfigFile,
        timeout: TimeInterval = 1.5
    ) async -> EdgeStatusResponse? {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(config.port)/__relaydock/status")!)
        request.timeoutInterval = timeout
        request.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
        return await performAsync(request: request, timeout: timeout) { data in
            guard let status = try? JSONDecoder().decode(EdgeStatusResponse.self, from: data),
                  status.ok,
                  status.protocolVersion == EdgeProtocol.version else { return nil }
            return status
        }
    }

    /// Runs health checks inside Edge — the owner of the script cache — and
    /// returns the per-entry outcomes for the app to persist into the pool.
    /// `scope: .all` checks every enabled proxy with a valid definition.
    public static func runChecksAsync(
        config: EdgeConfigFile,
        scope: EdgeCheckRequestScope,
        timeout: TimeInterval = 90
    ) async -> EdgeCheckResponse? {
        guard var components = URLComponents(
            string: "http://127.0.0.1:\(config.port)/__relaydock/check"
        ) else { return nil }
        switch scope {
        case .active:
            break
        case .all:
            components.queryItems = [URLQueryItem(name: "scope", value: "all")]
        case .entry(let entryID):
            components.queryItems = [URLQueryItem(name: "entry", value: entryID)]
        }
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
        return await performAsync(request: request, timeout: timeout) { data in
            try? JSONDecoder().decode(EdgeCheckResponse.self, from: data)
        }
    }

    private static func performAsync<T: Sendable>(
        request: URLRequest,
        timeout: TimeInterval,
        transform: @escaping @Sendable (Data) -> T?
    ) async -> T? {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else { return nil }
            return transform(data)
        } catch {
            return nil
        }
    }
}

/// The `/__relaydock/check` scopes callers can request.
public enum EdgeCheckRequestScope: Sendable {
    case active
    case all
    case entry(String)
}

/// The `/__relaydock/check` response shape. Edge maps its internal check
/// outcomes into this wire form; the app decodes it and persists the health
/// it describes into `proxies.json`.
public struct EdgeCheckResponse: Codable, Equatable, Sendable {
    public struct Result: Codable, Equatable, Sendable {
        public var ok: Bool
        public var latencyMs: Double?
        public var checkedAt: Double
        public var error: String?
        public var deferred: Bool
        public var retryAfter: Double?

        public init(
            ok: Bool,
            latencyMs: Double? = nil,
            checkedAt: Double,
            error: String? = nil,
            deferred: Bool = false,
            retryAfter: Double? = nil
        ) {
            self.ok = ok
            self.latencyMs = latencyMs
            self.checkedAt = checkedAt
            self.error = error
            self.deferred = deferred
            self.retryAfter = retryAfter
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            ok = (try? container.decode(Bool.self, forKey: .ok)) == true
            latencyMs = try container.decodeIfPresent(Double.self, forKey: .latencyMs)
            checkedAt = try container.decodeIfPresent(Double.self, forKey: .checkedAt)
                ?? Date().timeIntervalSince1970 * 1_000
            error = try container.decodeIfPresent(String.self, forKey: .error)
            deferred = (try? container.decode(Bool.self, forKey: .deferred)) == true
            retryAfter = try container.decodeIfPresent(Double.self, forKey: .retryAfter)
        }
    }

    public var results: [String: Result]

    public init(results: [String: Result]) {
        self.results = results
    }
}
