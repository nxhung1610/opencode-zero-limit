import CryptoKit
import Foundation

public enum ProxyMode: String, CaseIterable, Codable, Sendable, Identifiable {
    case off
    case manual
    case auto

    public var id: String { rawValue }
}

public struct ProxyHealth: Codable, Equatable, Sendable {
    public var ok: Bool
    public var latencyMs: Double?
    public var checkedAt: Double
    public var error: String?

    public init(ok: Bool, latencyMs: Double? = nil, checkedAt: Double = 0, error: String? = nil) {
        self.ok = ok
        self.latencyMs = latencyMs
        self.checkedAt = checkedAt
        self.error = error
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: ProxyCodingKey.self)
        ok = (try? container.decode(Bool.self, forKey: ProxyCodingKey("ok"))) == true
        latencyMs = try container.decodeIfPresent(Double.self, forKey: ProxyCodingKey("latencyMs"))
            ?? container.decodeIfPresent(Double.self, forKey: ProxyCodingKey("latency_ms"))
        checkedAt = try container.decodeIfPresent(Double.self, forKey: ProxyCodingKey("checkedAt"))
            ?? container.decodeIfPresent(Double.self, forKey: ProxyCodingKey("checked_at"))
            ?? 0
        error = try container.decodeIfPresent(String.self, forKey: ProxyCodingKey("error"))
    }
}

public struct ProxyEntry: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var label: String
    public var url: String
    public var enabled: Bool
    public var health: ProxyHealth?

    public init(id: String, label: String, url: String, enabled: Bool = true, health: ProxyHealth? = nil) {
        self.id = id
        self.label = label
        self.url = url
        self.enabled = enabled
        self.health = health
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: ProxyCodingKey.self)
        id = try container.decode(String.self, forKey: ProxyCodingKey("id"))
        url = try container.decode(String.self, forKey: ProxyCodingKey("url"))
        label = try container.decodeIfPresent(String.self, forKey: ProxyCodingKey("label")) ?? proxyLabel(for: url)
        enabled = try container.decodeIfPresent(Bool.self, forKey: ProxyCodingKey("enabled")) ?? true
        health = try container.decodeIfPresent(ProxyHealth.self, forKey: ProxyCodingKey("health"))
    }
}

public struct ProxyState: Codable, Equatable, Sendable {
    public var mode: ProxyMode
    public var manualId: String?
    public var proxies: [ProxyEntry]
    public var bindings: [String: String]

    public init(mode: ProxyMode = .off, manualId: String? = nil, proxies: [ProxyEntry] = [], bindings: [String: String] = [:]) {
        self.mode = mode
        self.manualId = manualId
        self.proxies = proxies
        self.bindings = bindings
    }

    public static let defaults = ProxyState()

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: ProxyCodingKey.self)
        let rawMode = try container.decodeIfPresent(String.self, forKey: ProxyCodingKey("mode")) ?? "off"
        mode = ProxyMode(rawValue: rawMode) ?? .off
        manualId = try container.decodeIfPresent(String.self, forKey: ProxyCodingKey("manualId"))
            ?? container.decodeIfPresent(String.self, forKey: ProxyCodingKey("manual_id"))
        proxies = (try? container.decode([ProxyEntry].self, forKey: ProxyCodingKey("proxies"))) ?? []
        bindings = (try? container.decode([String: String].self, forKey: ProxyCodingKey("bindings"))) ?? [:]
        if let manualId, !proxies.contains(where: { $0.id == manualId }) { self.manualId = nil }
    }
}

private struct ProxyCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil

    init(_ value: String) { stringValue = value }
    init?(stringValue: String) { self.init(stringValue) }
    init?(intValue: Int) { return nil }
}

public enum ProxyStoreError: LocalizedError, Equatable {
    case unreadable(String)
    case noManualSelection
    case manualSelectionDisabled(String)
    case autoHasNoEnabledProxy
    case autoHasNoHealthyProxy

    public var errorDescription: String? {
        switch self {
        case .unreadable(let message): "Cannot read proxies.json: \(message)"
        case .noManualSelection: "No proxy is selected for manual mode. Choose a proxy, or switch the proxy mode to Off."
        case .manualSelectionDisabled(let label): "The selected proxy (\(label)) is disabled. Enable it, choose another proxy, or switch the proxy mode to Off."
        case .autoHasNoEnabledProxy: "Auto mode needs at least one enabled proxy. Enable a proxy, or switch the proxy mode to Off."
        case .autoHasNoHealthyProxy: "No enabled proxy passed its last test. Test the pool again, enable a proxy, or switch the proxy mode to Off."
        }
    }
}

public struct ProxyStore: Sendable {
    public let fileURL: URL
    private let healthChecker: @Sendable (String) async -> ProxyHealth

    public init(
        configDirectory: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        healthChecker: @escaping @Sendable (String) async -> ProxyHealth = checkProxy
    ) {
        let directory: URL
        if let configDirectory {
            directory = configDirectory
        } else if let override = environment["RELAYDOCK_CONFIG_DIR"], !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            directory = URL(fileURLWithPath: override, isDirectory: true).standardizedFileURL
        } else {
            let homePath = environment["HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines)
            let home = homePath.flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
                ?? FileManager.default.homeDirectoryForCurrentUser
            directory = home.appending(path: "Library/Application Support", directoryHint: .isDirectory)
                .appending(path: SettingsStore.legacyNamespace, directoryHint: .isDirectory)
        }
        fileURL = directory.appending(path: "proxies.json")
        self.healthChecker = healthChecker
    }

    public func load() throws -> ProxyState {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return .defaults }
        do {
            return try JSONDecoder().decode(ProxyState.self, from: Data(contentsOf: fileURL))
        } catch {
            throw ProxyStoreError.unreadable(error.localizedDescription)
        }
    }

    @discardableResult
    public func save(_ state: ProxyState) throws -> ProxyState {
        let manager = FileManager.default
        let directory = fileURL.deletingLastPathComponent()
        try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var data = try encoder.encode(state)
        data.append(0x0A)
        try data.write(to: fileURL, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        return state
    }

    @discardableResult
    public func importProxies(_ text: String) throws -> ProxyState {
        var state = try load()
        for line in text.components(separatedBy: .newlines) {
            guard let url = parseProxyImportLine(line) else { continue }
            let id = proxyEntryID(for: url)
            guard !state.proxies.contains(where: { $0.id == id || $0.url == url }) else { continue }
            state.proxies.append(ProxyEntry(id: id, label: proxyLabel(for: url), url: url))
        }
        return try save(state)
    }

    @discardableResult
    public func remove(_ id: String) throws -> ProxyState {
        var state = try load()
        state.proxies.removeAll { $0.id == id }
        if state.manualId == id { state.manualId = nil }
        state.bindings = state.bindings.filter { $0.value != id }
        return try save(state)
    }

    @discardableResult
    public func setEnabled(_ id: String, enabled: Bool) throws -> ProxyState {
        var state = try load()
        if let index = state.proxies.firstIndex(where: { $0.id == id }) { state.proxies[index].enabled = enabled }
        return try save(state)
    }

    @discardableResult
    public func setMode(_ mode: ProxyMode, manualId: String?) throws -> ProxyState {
        var state = try load()
        state.mode = mode
        state.manualId = manualId.flatMap { candidate in state.proxies.contains(where: { $0.id == candidate }) ? candidate : nil }
        if mode == .manual && state.manualId == nil { state.mode = .off }
        return try save(state)
    }

    @discardableResult
    public func checkAll() async throws -> ProxyState {
        let initialState = try load()
        let entries = initialState.proxies.filter(\.enabled)
        let checkedURLs = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0.url) })
        let healthChecker = self.healthChecker
        let results = await withTaskGroup(of: (String, ProxyHealth).self) { group in
            for entry in entries {
                group.addTask { (entry.id, await healthChecker(entry.url)) }
            }
            var checked: [String: ProxyHealth] = [:]
            for await (id, health) in group { checked[id] = health }
            return checked
        }
        // Network checks suspend; merge results into the latest saved state rather than
        // saving the stale snapshot captured before the checks began.
        var latestState = try load()
        for index in latestState.proxies.indices {
            let entry = latestState.proxies[index]
            guard checkedURLs[entry.id] == entry.url,
                  let result = results[entry.id] else { continue }
            latestState.proxies[index].health = result
        }
        return try save(latestState)
    }

    /// Returns nil only for explicit Off mode. Auto and Manual always fail closed.
    public func selectForSpawn(accountID: String = "default") throws -> String? {
        var state = try load()
        if state.mode == .off { return nil }
        if state.mode == .manual {
            guard let selected = state.proxies.first(where: { $0.id == state.manualId }) else {
                throw ProxyStoreError.noManualSelection
            }
            guard selected.enabled else { throw ProxyStoreError.manualSelectionDisabled(selected.label) }
            return selected.url
        }

        guard state.proxies.contains(where: \.enabled) else { throw ProxyStoreError.autoHasNoEnabledProxy }
        let usable = state.proxies.filter { $0.enabled && $0.health?.ok != false }
        guard !usable.isEmpty else { throw ProxyStoreError.autoHasNoHealthyProxy }
        if let boundID = state.bindings[accountID], let bound = usable.first(where: { $0.id == boundID }) {
            return bound.url
        }
        let usedIDs = Set(state.bindings.values)
        let chosen = usable.first(where: { !usedIDs.contains($0.id) }) ?? usable[0]
        state.bindings[accountID] = chosen.id
        // A failed sticky-binding write must not turn an already-selected proxy into a direct launch.
        _ = try? save(state)
        return chosen.url
    }
}

public func parseProxyImportLine(_ value: String) -> String? {
    let line = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !line.isEmpty, !line.hasPrefix("#") else { return nil }
    let candidate: String
    if line.contains("://") {
        candidate = line
    } else if line.contains("@") || line.contains(":") {
        candidate = "http://\(line)"
    } else {
        return nil
    }
    guard let components = URLComponents(string: candidate),
          let scheme = components.scheme?.lowercased(),
          ["http", "https", "socks5", "socks5h"].contains(scheme),
          let host = components.host, !host.isEmpty,
          let port = components.port, (1...65_535).contains(port),
          components.url != nil else { return nil }
    return candidate
}

public func proxyEntryID(for url: String) -> String {
    let digest = SHA256.hash(data: Data(url.utf8))
    return "px_" + digest.prefix(8).map { String(format: "%02x", $0) }.joined()
}

public func proxyLabel(for url: String) -> String {
    let withoutScheme = url.components(separatedBy: "://").dropFirst().first ?? url
    let authority = withoutScheme.components(separatedBy: CharacterSet(charactersIn: "/?#")).first ?? withoutScheme
    return authority.components(separatedBy: "@").last ?? authority
}

public func maskedProxyURL(_ url: String) -> String {
    guard var components = URLComponents(string: url), components.user != nil || components.password != nil else { return url }
    components.user = "•••"
    components.password = nil
    return components.string ?? proxyLabel(for: url)
}

public func checkProxy(_ proxyURL: String) async -> ProxyHealth {
    let checkedAt = Date().timeIntervalSince1970 * 1_000
    guard parseProxyImportLine(proxyURL) == proxyURL else {
        return ProxyHealth(ok: false, checkedAt: checkedAt, error: "Invalid proxy URL or unsupported protocol")
    }
    guard let curl = curlBinary() else {
        return ProxyHealth(ok: false, checkedAt: checkedAt, error: "curl was not found on this Mac")
    }
    let result = await Task.detached(priority: .utility) {
        runProxyCheck(curl: curl, proxyURL: proxyURL)
    }.value
    let latency = result.latencySeconds.map { $0 * 1_000 }
    guard result.exitCode == 0, let status = result.statusCode, (200..<300).contains(status) else {
        let message = result.statusCode.map { "HTTP \($0)" } ?? result.message ?? "proxy check failed"
        return ProxyHealth(ok: false, latencyMs: nil, checkedAt: checkedAt, error: message)
    }
    return ProxyHealth(ok: true, latencyMs: latency, checkedAt: checkedAt)
}

private struct ProxyCurlResult: Sendable {
    var exitCode: Int32
    var statusCode: Int?
    var latencySeconds: Double?
    var message: String?
}

private func curlBinary() -> String? {
    let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
    let candidates = ["/usr/bin/curl", "/bin/curl"] + path.split(separator: ":").map { "\($0)/curl" }
    return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
}

private func runProxyCheck(curl: String, proxyURL: String) -> ProxyCurlResult {
    let process = Process()
    let input = Pipe()
    let output = Pipe()
    let errors = Pipe()
    process.executableURL = URL(fileURLWithPath: curl)
    process.arguments = [
        "--config", "-",
        "--noproxy", "",
        "--silent", "--show-error",
        "--max-time", "8",
        "--write-out", "%{http_code}\\n%{time_total}",
    ]
    process.environment = ProcessInfo.processInfo.environment
    process.standardInput = input
    process.standardOutput = output
    process.standardError = errors

    func failed(_ message: String) -> ProxyCurlResult {
        ProxyCurlResult(exitCode: -1, statusCode: nil, latencySeconds: nil, message: message)
    }

    do {
        try process.run()
        let escapedProxy = proxyURL
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: "")
        let configuration = "url = \"https://www.gstatic.com/generate_204\"\nproxy = \"\(escapedProxy)\"\n"
        try input.fileHandleForWriting.write(contentsOf: Data(configuration.utf8))
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
    } catch {
        if process.isRunning { process.terminate() }
        try? input.fileHandleForWriting.close()
        return failed(error.localizedDescription)
    }

    let outputText = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    let errorText = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let fields = outputText.split(whereSeparator: \.isNewline)
    let statusCode = fields.first.flatMap { Int($0) }
    let latency = fields.dropFirst().first.flatMap { Double($0) }
    let safeMessage = errorText?.replacingOccurrences(of: proxyURL, with: maskedProxyURL(proxyURL))
    return ProxyCurlResult(exitCode: process.terminationStatus, statusCode: statusCode, latencySeconds: latency, message: safeMessage)
}
