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
    /// A custom JavaScript entry. When present, consumers resolve the proxy by
    /// running this script at spawn time instead of using `url`.
    public var script: String?
    public var enabled: Bool
    public var health: ProxyHealth?

    public init(id: String, label: String, url: String, script: String? = nil, enabled: Bool = true, health: ProxyHealth? = nil) {
        self.id = id
        self.label = label
        self.url = url
        self.script = script
        self.enabled = enabled
        self.health = health
    }

    /// A custom script cannot be validated without running it; it counts as
    /// valid while it is non-empty. URL entries must parse with the shared
    /// import parser.
    public var hasValidDefinition: Bool {
        if let script { return !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return parseProxyImportLine(url) == url
    }

    public var isCustomScript: Bool { script != nil }

    /// Identifies the definition a health check ran against.
    var checkFingerprint: String { script ?? url }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: ProxyCodingKey.self)
        id = try container.decode(String.self, forKey: ProxyCodingKey("id"))
        script = try container.decodeIfPresent(String.self, forKey: ProxyCodingKey("script"))
        url = try container.decodeIfPresent(String.self, forKey: ProxyCodingKey("url")) ?? ""
        if script == nil, url.isEmpty {
            throw DecodingError.dataCorruptedError(
                forKey: ProxyCodingKey("url"),
                in: container,
                debugDescription: "A proxy entry must define a URL or a script."
            )
        }
        label = try container.decodeIfPresent(String.self, forKey: ProxyCodingKey("label"))
            ?? (script != nil ? "Custom script" : proxyLabel(for: url))
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

    public var enabledProxies: [ProxyEntry] {
        proxies.filter(\.enabled)
    }

    /// Enabled entries with a valid definition: a parseable URL, or a
    /// non-empty custom script.
    public var validEnabledProxies: [ProxyEntry] {
        enabledProxies.filter(\.hasValidDefinition)
    }

    /// Auto-eligible proxies include unchecked entries, but exclude entries with a known failed check.
    public var autoEligibleProxies: [ProxyEntry] {
        validEnabledProxies.filter { $0.health?.ok != false }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: ProxyCodingKey.self)
        let modeKey = ProxyCodingKey("mode")
        guard let rawMode = try container.decodeIfPresent(String.self, forKey: modeKey) else {
            throw DecodingError.keyNotFound(
                modeKey,
                DecodingError.Context(
                    codingPath: container.codingPath,
                    debugDescription: "A persisted proxy configuration must specify a mode."
                )
            )
        }
        guard let decodedMode = ProxyMode(rawValue: rawMode) else {
            throw DecodingError.dataCorruptedError(
                forKey: modeKey,
                in: container,
                debugDescription: "Unsupported proxy mode: \(rawMode)"
            )
        }
        mode = decodedMode
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
    case invalidImportLines([Int])
    case invalidSingleProxy
    case scriptNameRequired
    case scriptEmpty
    case proxyAlreadyExists(String)
    case noManualSelection
    case manualSelectionDisabled(String)
    case invalidProxyConfiguration(String)
    case scriptFailed(String, String)
    case autoHasNoEnabledProxy
    case autoHasNoValidProxy
    case autoHasNoHealthyProxy

    public var errorDescription: String? {
        switch self {
        case .unreadable(let message): "Cannot read proxies.json: \(message)"
        case .invalidImportLines(let lines):
            "Invalid proxy URL on line\(lines.count == 1 ? "" : "s") \(lines.map(String.init).joined(separator: ", ")). Fix the URL and try again. Supported schemes: http, https, socks4, socks4a, socks5, socks5h; host:port is also accepted."
        case .invalidSingleProxy:
            "Not a valid proxy URL. Supported schemes: http, https, socks4, socks4a, socks5, socks5h; host:port is also accepted."
        case .scriptNameRequired:
            "Give this script a name so it is recognizable in the pool."
        case .scriptEmpty:
            "Enter JavaScript that returns a proxy URL or host:port."
        case .proxyAlreadyExists(let label):
            "\(label) is already in the pool."
        case .noManualSelection: "No proxy is selected for manual mode. Choose a proxy, or switch the proxy mode to Off."
        case .manualSelectionDisabled(let label): "The selected proxy (\(label)) is disabled. Enable it or choose another enabled proxy."
        case .invalidProxyConfiguration(let label): "The selected proxy (\(label)) has an invalid or unsupported URL. Fix its configuration before routing OpenCode."
        case .scriptFailed(let label, let reason): "\(label) could not resolve a proxy. \(reason)"
        case .autoHasNoEnabledProxy: "Auto mode needs at least one enabled proxy. Enable a proxy, or switch the proxy mode to Off."
        case .autoHasNoValidProxy: "Auto mode has no enabled proxy with a valid supported URL. Fix the proxy pool, or switch the proxy mode to Off."
        case .autoHasNoHealthyProxy: "No enabled proxy passed its last test. Test the pool again, enable a proxy, or switch the proxy mode to Off."
        }
    }
}

public struct ProxyStore: Sendable {
    public let fileURL: URL
    private let healthChecker: @Sendable (String) async -> ProxyHealth
    private static let maxConcurrentHealthChecks = 4

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
            // Keep existing proxy pools in place; this library does not migrate or delete user data.
            directory = home.appending(path: "Library/Application Support", directoryHint: .isDirectory)
                .appending(path: "com.nxhung.opencodezerolimit", directoryHint: .isDirectory)
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
        let lines = text.components(separatedBy: .newlines)
        let invalidLines = lines.enumerated().compactMap { index, line -> Int? in
            let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedLine.isEmpty, !trimmedLine.hasPrefix("#") else { return nil }
            return parseProxyImportLine(line) == nil ? index + 1 : nil
        }
        guard invalidLines.isEmpty else { throw ProxyStoreError.invalidImportLines(invalidLines) }

        var state = try load()
        for line in lines {
            guard let url = parseProxyImportLine(line) else { continue }
            let id = proxyEntryID(for: url)
            guard !state.proxies.contains(where: { $0.id == id || $0.url == url }) else { continue }
            state.proxies.append(ProxyEntry(id: id, label: proxyLabel(for: url), url: url))
        }
        return try save(state)
    }

    /// Adds a single URL entry. The input goes through the same parser as bulk
    /// import lines, so a full URL or host:port is accepted.
    @discardableResult
    public func addProxyURL(_ input: String) throws -> ProxyState {
        guard let url = parseProxyImportLine(input) else { throw ProxyStoreError.invalidSingleProxy }
        var state = try load()
        guard !state.proxies.contains(where: { $0.id == proxyEntryID(for: url) || $0.url == url }) else {
            throw ProxyStoreError.proxyAlreadyExists(proxyLabel(for: url))
        }
        state.proxies.append(ProxyEntry(id: proxyEntryID(for: url), label: proxyLabel(for: url), url: url))
        return try save(state)
    }

    /// Adds a custom JavaScript entry. The script is stored as written and runs
    /// only when a consumer selects a route.
    @discardableResult
    public func addProxyScript(name: String, script: String) throws -> ProxyState {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { throw ProxyStoreError.scriptNameRequired }
        guard !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ProxyStoreError.scriptEmpty }
        var state = try load()
        guard !state.proxies.contains(where: { $0.id == proxyScriptEntryID(for: script) || $0.script == script }) else {
            throw ProxyStoreError.proxyAlreadyExists("This script")
        }
        state.proxies.append(ProxyEntry(id: proxyScriptEntryID(for: script), label: trimmedName, url: "", script: script))
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
        let selectedProxy = manualId.flatMap { candidate in state.proxies.first(where: { $0.id == candidate }) }
        if mode == .manual {
            guard let selectedProxy else { throw ProxyStoreError.noManualSelection }
            guard selectedProxy.enabled else { throw ProxyStoreError.manualSelectionDisabled(selectedProxy.label) }
            guard selectedProxy.hasValidDefinition else {
                throw ProxyStoreError.invalidProxyConfiguration(selectedProxy.label)
            }
        }
        state.mode = mode
        state.manualId = selectedProxy?.id
        return try save(state)
    }

    @discardableResult
    public func checkAll() async throws -> ProxyState {
        let initialState = try load()
        let entries = initialState.proxies.filter(\.enabled)
        let fingerprints = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0.checkFingerprint) })
        let results = await withTaskGroup(of: (String, ProxyHealth).self) { group in
            var iterator = entries.makeIterator()
            for _ in 0..<min(Self.maxConcurrentHealthChecks, entries.count) {
                guard let entry = iterator.next() else { break }
                group.addTask { await self.checkEntry(entry) }
            }
            var checked: [String: ProxyHealth] = [:]
            while let (id, health) = await group.next() {
                checked[id] = health
                if let entry = iterator.next() {
                    group.addTask { await self.checkEntry(entry) }
                }
            }
            return checked
        }
        // Network checks suspend; merge results into the latest saved state rather than
        // saving the stale snapshot captured before the checks began.
        var latestState = try load()
        for index in latestState.proxies.indices {
            let entry = latestState.proxies[index]
            guard fingerprints[entry.id] == entry.checkFingerprint,
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
            guard selected.hasValidDefinition else {
                throw ProxyStoreError.invalidProxyConfiguration(selected.label)
            }
            return try resolveSpawnURL(selected)
        }

        let enabled = state.enabledProxies
        guard !enabled.isEmpty else { throw ProxyStoreError.autoHasNoEnabledProxy }
        let valid = state.validEnabledProxies
        guard !valid.isEmpty else { throw ProxyStoreError.autoHasNoValidProxy }
        let usable = state.autoEligibleProxies
        guard !usable.isEmpty else { throw ProxyStoreError.autoHasNoHealthyProxy }
        if let boundID = state.bindings[accountID], let bound = usable.first(where: { $0.id == boundID }) {
            return try resolveSpawnURL(bound)
        }
        let usedIDs = Set(state.bindings.values)
        let chosen = usable.first(where: { !usedIDs.contains($0.id) }) ?? usable[0]
        state.bindings[accountID] = chosen.id
        // A failed sticky-binding write must not turn an already-selected proxy into a direct launch.
        _ = try? save(state)
        return try resolveSpawnURL(chosen)
    }

    /// Turns a selected entry into the concrete proxy URL for the child
    /// process. Custom scripts run here; any failure keeps the launch
    /// fail-closed instead of silently going direct.
    private func resolveSpawnURL(_ entry: ProxyEntry) throws -> String {
        if let script = entry.script {
            do {
                return try ProxyScriptRunner.resolve(script)
            } catch {
                throw ProxyStoreError.scriptFailed(entry.label, error.localizedDescription)
            }
        }
        guard parseProxyImportLine(entry.url) == entry.url else {
            throw ProxyStoreError.invalidProxyConfiguration(entry.label)
        }
        return entry.url
    }

    /// Runs one health check. Custom scripts resolve to a concrete URL first;
    /// a script failure is recorded as a failed check.
    private func checkEntry(_ entry: ProxyEntry) async -> (String, ProxyHealth) {
        guard let script = entry.script else {
            return (entry.id, await healthChecker(entry.url))
        }
        do {
            let resolved = try ProxyScriptRunner.resolve(script)
            return (entry.id, await healthChecker(resolved))
        } catch {
            return (entry.id, ProxyHealth(
                ok: false,
                latencyMs: nil,
                checkedAt: Date().timeIntervalSince1970 * 1_000,
                error: error.localizedDescription
            ))
        }
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
          ["http", "https", "socks4", "socks4a", "socks5", "socks5h"].contains(scheme),
          let host = components.host, !host.isEmpty,
          let port = components.port, (1...65_535).contains(port),
          components.url != nil else { return nil }
    return candidate
}

public func proxyEntryID(for url: String) -> String {
    let digest = SHA256.hash(data: Data(url.utf8))
    return "px_" + digest.prefix(8).map { String(format: "%02x", $0) }.joined()
}

public func proxyScriptEntryID(for script: String) -> String {
    proxyEntryID(for: "relaydock-script:" + script)
}

public func proxyLabel(for url: String) -> String {
    let withoutScheme = url.components(separatedBy: "://").dropFirst().first ?? url
    let authority = withoutScheme.components(separatedBy: CharacterSet(charactersIn: "/?#")).first ?? withoutScheme
    return authority.components(separatedBy: "@").last ?? authority
}

public func maskedProxyURL(_ url: String) -> String {
    guard let schemeRange = url.range(of: "://") else { return url }
    let rest = String(url[schemeRange.upperBound...])
    // The authority ends at the first path, query, or fragment delimiter.
    let authorityEnd = rest.firstIndex { "/?#".contains($0) } ?? rest.endIndex
    let authority = rest[..<authorityEnd]
    guard let at = authority.range(of: "@", options: .backwards) else { return url }
    // Built by hand instead of via URLComponents, which would percent-encode
    // the mask into %E2%80%A2 bullets.
    return String(url[..<schemeRange.upperBound]) + "•••@" + authority[at.upperBound...] + rest[authorityEnd...]
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
