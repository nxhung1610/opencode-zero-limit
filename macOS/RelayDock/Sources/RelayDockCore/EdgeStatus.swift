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
        public var tunnelsTotal: Int
        public var tunnelsActive: Int

        public init(
            resolutions: Int = 0,
            switches: Int = 0,
            dialFailures: Int = 0,
            streamFailures: Int = 0,
            tunnelsTotal: Int = 0,
            tunnelsActive: Int = 0
        ) {
            self.resolutions = resolutions
            self.switches = switches
            self.dialFailures = dialFailures
            self.streamFailures = streamFailures
            self.tunnelsTotal = tunnelsTotal
            self.tunnelsActive = tunnelsActive
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            resolutions = try container.decode(Int.self, forKey: .resolutions)
            switches = try container.decode(Int.self, forKey: .switches)
            dialFailures = try container.decode(Int.self, forKey: .dialFailures)
            streamFailures = try container.decodeIfPresent(Int.self, forKey: .streamFailures) ?? 0
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
        self.launchedAt = launchedAt
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
}
