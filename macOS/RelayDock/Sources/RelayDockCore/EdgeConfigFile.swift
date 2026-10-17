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

    public var version: Int
    public var port: Int
    public var token: String

    public init(
        version: Int = EdgeConfigFile.currentVersion,
        port: Int = EdgeConfigFile.defaultPort,
        token: String
    ) {
        self.version = version
        self.port = port
        self.token = token
    }

    /// `http://<token>:@127.0.0.1:<port>` — the constant value of every proxy
    /// var (the trailing colon keeps Bun's proxy parser happy, see above)iable a wrapped process holds.
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
              let config = try? JSONDecoder().decode(EdgeConfigFile.self, from: data),
              config.version == currentVersion,
              (1...65_535).contains(config.port),
              !config.token.isEmpty else { return nil }
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
