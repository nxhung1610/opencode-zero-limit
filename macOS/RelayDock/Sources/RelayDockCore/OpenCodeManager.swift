import Darwin
import Foundation

public struct OpenCodeStatus: Equatable, Sendable {
    public var running: Bool
    public var healthy: Bool
    public var port: Int?
    public var version: String?
    public var error: String?

    public init(running: Bool, healthy: Bool, port: Int?, version: String?, error: String?) {
        self.running = running
        self.healthy = healthy
        self.port = port
        self.version = version
        self.error = error
    }

    public static let stopped = OpenCodeStatus(running: false, healthy: false, port: nil, version: nil, error: nil)
}

public func buildOpenCodeProxyEnvironment(proxyURL: String?, base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
    var environment = base
    environment["NO_PROXY"] = mergeNoProxy(base["NO_PROXY"])
    environment["no_proxy"] = mergeNoProxy(base["no_proxy"])
    let proxyKeys = ["HTTP_PROXY", "http_proxy", "HTTPS_PROXY", "https_proxy", "ALL_PROXY", "all_proxy"]
    if let proxyURL {
        for key in proxyKeys { environment[key] = proxyURL }
    } else {
        for key in proxyKeys { environment.removeValue(forKey: key) }
    }
    environment.removeValue(forKey: "OPENCODE_SERVER_PASSWORD")
    environment.removeValue(forKey: "OPENCODE_SERVER_USERNAME")
    return environment
}

private func mergeNoProxy(_ value: String?) -> String {
    var entries = (value ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    for local in ["localhost", "127.0.0.1"] where !entries.contains(local) { entries.append(local) }
    return entries.joined(separator: ",")
}

public func resolveOpenCodeBinary(configured: String? = nil, environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
    let configuredHome = environment["HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines)
    let home = configuredHome.flatMap { $0.isEmpty ? nil : $0 }
        ?? environment["USERPROFILE"]
        ?? FileManager.default.homeDirectoryForCurrentUser.path
    let explicit = [environment["OPENCODE_BIN"], configured]
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
    for path in explicit {
        let expanded = expandHome(path, home: home)
        if isExecutable(expanded) { return canonicalPath(expanded) }
    }

    var directories = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
    directories += ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
    directories += [".local/bin", ".bun/bin", ".npm-global/bin", ".yarn/bin"].map { "\(home)/\($0)" }
    let names = directories.map { "\($0)/opencode" }

    let nvmRoot = URL(fileURLWithPath: home).appending(path: ".nvm/versions/node", directoryHint: .isDirectory)
    if let versions = try? FileManager.default.contentsOfDirectory(atPath: nvmRoot.path).sorted(by: >) {
        let nvmCandidates = versions.map { nvmRoot.appending(path: $0, directoryHint: .isDirectory).appending(path: "bin/opencode").path }
        for candidate in nvmCandidates where isExecutable(candidate) { return canonicalPath(candidate) }
    }

    return names.first(where: isExecutable).map(canonicalPath)
}

private func expandHome(_ path: String, home: String) -> String {
    if path == "~" { return home }
    if path.hasPrefix("~/") { return URL(fileURLWithPath: home).appending(path: String(path.dropFirst(2))).path }
    return path
}

private func isExecutable(_ path: String) -> Bool {
    FileManager.default.fileExists(atPath: path) && FileManager.default.isExecutableFile(atPath: path)
}

private func canonicalPath(_ path: String) -> String {
    URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
}

public typealias OpenCodeHealthProbe = @MainActor @Sendable (_ port: Int, _ majorVersion: Int, _ password: String?) async -> String?

@MainActor
public final class OpenCodeManager {
    private let settings: SettingsStore
    private let proxySelector: @Sendable (_ accountID: String?) throws -> String?
    private let healthProbe: OpenCodeHealthProbe
    private var process: Process?
    private var port: Int?
    private var cliMajorVersion: Int?
    private var serverPassword: String?
    private var activeProxyAccountID: String?
    private var selectedProxyURL: String?
    private var error: String?
    private var startTask: Task<OpenCodeStatus, Never>?

    public init(
        settings: SettingsStore,
        proxySelector: @escaping @Sendable (_ accountID: String?) throws -> String?,
        healthProbe: OpenCodeHealthProbe? = nil
    ) {
        self.settings = settings
        self.proxySelector = proxySelector
        self.healthProbe = healthProbe ?? { port, majorVersion, password in
            await OpenCodeManager.probe(port: port, majorVersion: majorVersion, password: password)
        }
    }

    public func getPort() -> Int? { port }
    public func getCLIMajorVersion() -> Int? { cliMajorVersion }

    public func apiHeaders() -> [String: String] {
        guard let serverPassword else { return [:] }
        let credentials = Data("opencode:\(serverPassword)".utf8).base64EncodedString()
        return ["Authorization": "Basic \(credentials)"]
    }

    public func start() async -> OpenCodeStatus {
        if let startTask { return await startTask.value }
        let task = Task { @MainActor [weak self] in
            guard let self else { return OpenCodeStatus.stopped }
            return await self.startInternal()
        }
        startTask = task
        let result = await task.value
        startTask = nil
        return result
    }

    public func status() async -> OpenCodeStatus {
        guard let process else { return snapshot(running: false, healthy: false, port: nil) }
        guard process.isRunning else {
            recordExit(process)
            return snapshot(running: false, healthy: false, port: nil)
        }
        guard let port, let cliMajorVersion else { return snapshot(running: true, healthy: false, port: port) }
        if let version = await healthProbe(port, cliMajorVersion, serverPassword) {
            error = nil
            return OpenCodeStatus(running: true, healthy: true, port: port, version: version, error: nil)
        }
        return snapshot(running: true, healthy: false, port: port)
    }

    /// Rebinds Auto-mode routing after OpenCode activates a Console credential.
    /// Off and Manual modes resolve to the same route, so they avoid a restart.
    public func activeConsoleAccountDidChange(_ accountID: String) async -> OpenCodeStatus {
        activeProxyAccountID = accountID
        guard let process, process.isRunning else { return await status() }

        let nextProxy: String?
        do {
            nextProxy = try proxySelector(accountID)
        } catch {
            let message = error.localizedDescription
            await stopCurrentProcess()
            self.error = message
            return snapshot(running: false, healthy: false, port: nil)
        }

        guard nextProxy != selectedProxyURL else { return await status() }
        return await restart()
    }

    public func stop() async -> OpenCodeStatus {
        if let startTask { _ = await startTask.value }
        await stopCurrentProcess()
        return snapshot(running: false, healthy: false, port: nil)
    }

    public func restart() async -> OpenCodeStatus {
        _ = await stop()
        return await start()
    }

    public func terminateImmediately() {
        guard let process, process.isRunning else { return }
        process.terminate()
    }

    private func startInternal() async -> OpenCodeStatus {
        if let process {
            if process.isRunning {
                let existingStatus = await status()
                if existingStatus.healthy { return existingStatus }
                await stopCurrentProcess()
            } else {
                recordExit(process)
            }
        }

        guard let binary = resolveOpenCodeBinary(configured: settings.load().opencodeBin) else {
            error = "opencode binary not found (install opencode or set OPENCODE_BIN)"
            return snapshot(running: false, healthy: false, port: nil)
        }

        let versionOutput: String
        do {
            versionOutput = try await Self.readVersion(from: binary)
        } catch {
            self.error = "could not read OpenCode CLI version: \(error.localizedDescription)"
            return snapshot(running: false, healthy: false, port: nil)
        }
        guard let version = Self.parseVersion(versionOutput) else {
            error = "could not parse OpenCode CLI version: \(versionOutput.isEmpty ? "empty output" : versionOutput)"
            return snapshot(running: false, healthy: false, port: nil)
        }
        guard version.major == 1 || version.major == 2 else {
            cliMajorVersion = nil
            error = "unsupported OpenCode CLI major version: \(version.major)"
            return snapshot(running: false, healthy: false, port: nil)
        }
        cliMajorVersion = version.major

        let selectedProxy: String?
        do {
            selectedProxy = try proxySelector(activeProxyAccountID)
        } catch {
            cliMajorVersion = nil
            serverPassword = nil
            self.error = error.localizedDescription
            return snapshot(running: false, healthy: false, port: nil)
        }

        let newPort: Int
        do {
            newPort = try Self.freeLocalPort()
        } catch {
            cliMajorVersion = nil
            self.error = "could not allocate a local port: \(error.localizedDescription)"
            return snapshot(running: false, healthy: false, port: nil)
        }

        serverPassword = version.major == 2 ? Self.makePassword() : nil
        var environment = buildOpenCodeProxyEnvironment(proxyURL: selectedProxy)
        if let serverPassword {
            environment["OPENCODE_SERVER_PASSWORD"] = serverPassword
            environment["OPENCODE_SERVER_USERNAME"] = "opencode"
        }

        let child = Process()
        child.executableURL = URL(fileURLWithPath: binary)
        child.arguments = ["serve", "--port", String(newPort), "--hostname", "127.0.0.1"]
        child.environment = environment
        child.standardInput = FileHandle.nullDevice
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        do {
            try child.run()
        } catch {
            self.error = "failed to spawn opencode serve: \(error.localizedDescription)"
            serverPassword = nil
            cliMajorVersion = nil
            return snapshot(running: false, healthy: false, port: nil)
        }
        process = child
        port = newPort
        selectedProxyURL = selectedProxy
        error = nil

        for _ in 0..<40 {
            guard child.isRunning else {
                recordExit(child)
                return snapshot(running: false, healthy: false, port: nil)
            }
            if let healthyVersion = await healthProbe(newPort, version.major, serverPassword) {
                error = nil
                return OpenCodeStatus(running: true, healthy: true, port: newPort, version: healthyVersion, error: nil)
            }
            try? await Task.sleep(for: .milliseconds(250))
        }

        error = "opencode serve did not become healthy in time"
        return snapshot(running: child.isRunning, healthy: false, port: newPort)
    }

    private func stopCurrentProcess() async {
        guard let child = process else {
            port = nil
            cliMajorVersion = nil
            serverPassword = nil
            selectedProxyURL = nil
            error = nil
            return
        }
        if child.isRunning {
            child.terminate()
            if !(await waitForExit(child, timeoutMilliseconds: 2_000)) {
                _ = Darwin.kill(child.processIdentifier, SIGKILL)
                _ = await waitForExit(child, timeoutMilliseconds: 1_000)
            }
        }
        if process === child { process = nil }
        port = nil
        cliMajorVersion = nil
        serverPassword = nil
        selectedProxyURL = nil
        error = nil
    }

    private func waitForExit(_ child: Process, timeoutMilliseconds: Int) async -> Bool {
        let deadline = Date().addingTimeInterval(Double(timeoutMilliseconds) / 1_000)
        while child.isRunning && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        return !child.isRunning
    }

    private func recordExit(_ child: Process) {
        if process === child { process = nil }
        let code = child.terminationStatus
        error = "opencode serve exited with code \(code)"
        port = nil
        cliMajorVersion = nil
        serverPassword = nil
        selectedProxyURL = nil
    }

    private func snapshot(running: Bool, healthy: Bool, port: Int?) -> OpenCodeStatus {
        OpenCodeStatus(running: running, healthy: healthy, port: port, version: nil, error: error)
    }

    private static func freeLocalPort() throws -> Int {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        defer { _ = Darwin.close(descriptor) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(0)
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }

        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let result = withUnsafeMutablePointer(to: &actual) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &length)
            }
        }
        guard result == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        return Int(UInt16(bigEndian: actual.sin_port))
    }

    private static func makePassword() -> String {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func readVersion(from binary: String) async throws -> String {
        let child = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        child.executableURL = URL(fileURLWithPath: binary)
        child.arguments = ["--version"]
        child.environment = ProcessInfo.processInfo.environment
        child.standardInput = FileHandle.nullDevice
        child.standardOutput = stdout
        child.standardError = stderr
        try child.run()

        let deadline = Date().addingTimeInterval(5)
        while child.isRunning && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        if child.isRunning {
            child.terminate()
            throw NSError(domain: "RelayDock.OpenCode", code: 1, userInfo: [NSLocalizedDescriptionKey: "version command timed out"])
        }
        let out = stdout.fileHandleForReading.readDataToEndOfFile()
        let err = stderr.fileHandleForReading.readDataToEndOfFile()
        guard child.terminationStatus == 0 else {
            let detail = String(data: err, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw NSError(domain: "RelayDock.OpenCode", code: Int(child.terminationStatus), userInfo: [NSLocalizedDescriptionKey: detail.isEmpty ? "version command exited with code \(child.terminationStatus)" : detail])
        }
        return String(data: out, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private static func parseVersion(_ output: String) -> (major: Int, full: String)? {
        let pattern = #"\bv?(\d+)\.\d+\.\d+\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: output, range: NSRange(output.startIndex..., in: output)),
              let majorRange = Range(match.range(at: 1), in: output),
              let fullRange = Range(match.range, in: output),
              let major = Int(output[majorRange]) else { return nil }
        return (major, String(output[fullRange]))
    }

    private static func probe(port: Int, majorVersion: Int, password: String?) async -> String? {
        let isV2 = majorVersion == 2
        let endpoint = isV2 ? "/api/info" : "/global/health"
        guard let url = URL(string: "http://127.0.0.1:\(port)\(endpoint)") else { return nil }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 1)
        if isV2, let password {
            let credentials = Data("opencode:\(password)".utf8).base64EncodedString()
            request.setValue("Basic \(credentials)", forHTTPHeaderField: "Authorization")
        }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode),
                  let body = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let version = body["version"] as? String else { return nil }
            return isV2 || (body["healthy"] as? Bool == true) ? version : nil
        } catch {
            return nil
        }
    }
}
