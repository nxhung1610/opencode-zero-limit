import Foundation

/// The configuration the installer writes for RelayDock Edge (`edge.json`
/// next to `proxies.json`): the loopback port Edge binds and the per-install
/// token every consumer presents.
///
/// The token rides in the proxy URL's userinfo. The colon after it is
/// load-bearing: OpenCode's fetch (Bun) never connects when the userinfo has
/// no `username:password` colon, but sends `Proxy-Authorization: Basic`
/// (`base64("<token>:")`) when it does — verified against opencode v2 in the
/// Docker sandbox.
///
/// The port is immutable once consumers hold it. The installer probes for a
/// free port at install time; a running Edge that cannot bind exits loudly
/// instead of renumbering and stranding the environments of long-lived
/// processes.
public struct EdgeConfigFile: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public static let defaultPort = 57211

    /// One extra loopback listener pinned to a single pool entry (P3
    /// per-account ports). Consumers that dial this port always route through
    /// that account; the global mode and the rest of the pool never apply.
    public struct Listener: Codable, Equatable, Sendable {
        public var port: Int
        public var entryID: String

        public init(port: Int, entryID: String) {
            self.port = port
            self.entryID = entryID
        }
    }

    public var version: Int
    public var port: Int
    public var token: String
    public var listeners: [Listener]

    public init(
        version: Int = EdgeConfigFile.currentVersion,
        port: Int = EdgeConfigFile.defaultPort,
        token: String,
        listeners: [Listener] = []
    ) {
        self.version = version
        self.port = port
        self.token = token
        self.listeners = listeners
    }

    /// Older `edge.json` files have no `listeners` key; decoding tolerates
    /// its absence so upgrades never strand a working install.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        port = try container.decode(Int.self, forKey: .port)
        token = try container.decode(String.self, forKey: .token)
        listeners = try container.decodeIfPresent([Listener].self, forKey: .listeners) ?? []
    }

    /// `http://<token>:@127.0.0.1:<port>` — the constant value of every proxy
    /// var (the trailing colon keeps Bun's proxy parser happy, see above) — the constant value a wrapped process holds.
    public var proxyURL: String {
        Self.proxyURL(token: token, port: port)
    }

    public static func proxyURL(token: String, port: Int) -> String {
        "http://\(token):@127.0.0.1:\(port)"
    }

    /// The directory that holds `proxies.json`, `edge.json`, and Edge's state
    /// files. Mirrors `ProxyStore`'s resolution: an explicit directory, then
    /// `RELAYDOCK_CONFIG_DIR`, then the app support folder. Sandboxed or
    /// scripted scenarios must set `RELAYDOCK_CONFIG_DIR`.
    public static func configDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let override = environment["RELAYDOCK_CONFIG_DIR"],
           !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true).standardizedFileURL
        }
        let homePath = environment["HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let home = homePath.flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser
        return home.appending(path: "Library/Application Support", directoryHint: .isDirectory)
            .appending(path: "com.nxhung.opencodezerolimit", directoryHint: .isDirectory)
    }

    public static func fileURL(
        configDirectory: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        (configDirectory ?? Self.configDirectory(environment: environment))
            .appending(path: "edge.json")
    }

    /// Loads a usable configuration. A missing, damaged, or future-version
    /// file returns nil so callers fail closed with a reinstall hint instead
    /// of guessing a port or token.
    public static func load(from url: URL) -> EdgeConfigFile? {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(EdgeConfigFile.self, from: data),
              decoded.version == currentVersion,
              (1...65_535).contains(decoded.port),
              !decoded.token.isEmpty else { return nil }
        // Listener entries are best-effort hardening: one bad pin must never
        // take the primary listener down with it, so invalid entries are
        // dropped instead of failing the whole file.
        var config = decoded
        var seenPinnedPorts: Set<Int> = []
        config.listeners = config.listeners.filter { listener in
            (1...65_535).contains(listener.port)
                && listener.port != config.port
                && !listener.entryID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && seenPinnedPorts.insert(listener.port).inserted
        }
        return config
    }

    public func save(to url: URL) throws {
        let manager = FileManager.default
        try manager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var data = try encoder.encode(self)
        data.append(0x0A)
        try data.write(to: url, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// A fresh 128-bit token in hex. URL-safe inside proxy userinfo, so the
    /// consumer-side environment never needs percent-encoding.
    public static func makeRandomToken() -> String {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<16).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}
