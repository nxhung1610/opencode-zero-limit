import Darwin
import Foundation
import RelayDockCore

/// A deliberately small live request made after a proxy has passed its
/// connectivity check. OpenCode's own session.error plugin reports a free-tier
/// error to Edge, tagged with the entry the request is testing.
enum OpenCodeFreeUsageProbe {
    enum Outcome: Equatable, Sendable {
        case passed
        case failed
        case timedOut
        case freeUsageLimited(retryAfterMs: Double)
    }

    struct CommandResult: Equatable, Sendable {
        var status: Int32
        var stdout: String
        var timedOut: Bool
    }

    typealias CommandRunner = @Sendable (String, [String: String], TimeInterval) async -> CommandResult

    struct ProbeBridge: Sendable {
        var proxyURL: String
        var port: Int
        var configDirectory: URL
        var cleanup: @Sendable () -> Void
    }

    typealias BridgeFactory = @Sendable (ProxyEntry, String, [String: String]) async throws -> ProbeBridge

    private static let modelListTimeout: TimeInterval = 20
    private static let requestTimeout: TimeInterval = 45
    private static let prompt = "Reply with only OK."
    private static let maximumCooldownMs: Double = 7 * 24 * 60 * 60 * 1_000

    static func findFreeModel(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        runner: @escaping CommandRunner = runCommand
    ) async -> String? {
        var childEnvironment = environment
        childEnvironment["RELAYDOCK_QUIET"] = "1"
        let result = await runner("exec /usr/bin/env opencode models", childEnvironment, modelListTimeout)
        guard result.status == 0, !result.timedOut else { return nil }
        let models = freeModelIDs(in: result.stdout)
        if let requested = environment["RELAYDOCK_FREE_USAGE_TEST_MODEL"], models.contains(requested) {
            return requested
        }
        for preferred in [
            "opencode/mimo-v2.6-flash-free",
            "opencode/beam-free",
            "opencode/big-pickle",
        ] where models.contains(preferred) {
            return preferred
        }
        return models.first
    }

    /// OpenCode's current model listing is plain text. Parse only provider
    /// model IDs known to be free; avoid silently testing a paid model.
    static func freeModelIDs(in output: String) -> [String] {
        var seen: Set<String> = []
        var models: [String] = []
        let pattern = try? NSRegularExpression(pattern: #"opencode/[A-Za-z0-9._-]+"#)
        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = String(rawLine)
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            guard let match = pattern?.firstMatch(in: line, range: range),
                  let tokenRange = Range(match.range, in: line) else { continue }
            let token = String(line[tokenRange])
            let modelName = token.dropFirst("opencode/".count).lowercased()
            guard modelName.contains("free") || modelName == "big-pickle",
                  seen.insert(token).inserted else { continue }
            models.append(token)
        }
        return models
    }

    static func run(
        entry: ProxyEntry,
        proxyURL: String,
        edgeConfig: EdgeConfigFile,
        model: String,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        runner: @escaping CommandRunner = runCommand,
        bridgeFactory: @escaping BridgeFactory = { entry, proxyURL, environment in
            try await startIsolatedEdge(entry: entry, proxyURL: proxyURL, environment: environment)
        }
    ) async -> Outcome {
        guard let normalizedURL = parseProxyImportLine(proxyURL),
              entry.enabled,
              !entry.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              (1...65_535).contains(edgeConfig.port) else { return .failed }

        let bridge: ProbeBridge
        do {
            bridge = try await bridgeFactory(entry, normalizedURL, environment)
        } catch {
            return .failed
        }
        defer { bridge.cleanup() }
        guard let bridgeURL = parseProxyImportLine(bridge.proxyURL),
              let components = URLComponents(string: bridgeURL),
              components.scheme == "http",
              ["127.0.0.1", "localhost", "::1"].contains(components.host?.lowercased() ?? ""),
              components.port == bridge.port,
              (1...65_535).contains(bridge.port) else { return .failed }

        var childEnvironment = buildOpenCodeProxyEnvironment(proxyURL: bridgeURL, base: environment)
        // An inherited wildcard NO_PROXY would otherwise turn this into a
        // direct provider request and falsely test the wrong path.
        childEnvironment["NO_PROXY"] = "localhost,127.0.0.1"
        childEnvironment["no_proxy"] = "localhost,127.0.0.1"
        childEnvironment["RELAYDOCK_QUIET"] = "1"
        childEnvironment["RELAYDOCK_TEST_PROXY_URL"] = bridgeURL
        childEnvironment["RELAYDOCK_TEST_PROXY_ID"] = entry.id
        childEnvironment["RELAYDOCK_TEST_EDGE_PORT"] = String(bridge.port)

        let command = "exec /usr/bin/env opencode run --standalone --model \(shellQuote(model)) --format json \(shellQuote(prompt))"
        let result = await runner(command, childEnvironment, requestTimeout)
        let outputCooldown = freeUsageLimitCooldown(in: result.stdout)
        if let recordedCooldown = await recordedCooldown(
            in: bridge,
            entry: entry,
            waitForReport: result.status != 0 || outputCooldown != nil ? 1.2 : 0
        ) {
            return .freeUsageLimited(retryAfterMs: recordedCooldown)
        }
        if let outputCooldown { return .freeUsageLimited(retryAfterMs: outputCooldown) }
        if result.timedOut { return .timedOut }
        return result.status == 0 ? .passed : .failed
    }

    private static func recordedCooldown(
        in bridge: ProbeBridge,
        entry: ProxyEntry,
        waitForReport: TimeInterval
    ) async -> Double? {
        let deadline = Date().addingTimeInterval(waitForReport)
        repeat {
            let now = Date().timeIntervalSince1970
            let state = ProxyState(
                mode: .manual,
                manualId: entry.id,
                proxies: [ProxyEntry(id: entry.id, label: entry.label, url: entry.url)]
            )
            let applied = FreeUsageLimitStore(configDirectory: bridge.configDirectory).applying(to: state, now: now)
            if let resetAt = applied.proxies.first?.freeUsageLimitedUntil, resetAt > now {
                return boundedCooldown(
                    (resetAt - now) * 1_000,
                    fallback: defaultCooldownMilliseconds(nowMilliseconds: now * 1_000)
                )
            }
            guard Date() < deadline else { break }
            do {
                try await Task.sleep(for: .milliseconds(100))
            } catch {
                break
            }
        } while true
        return nil
    }

    /// Recognize the same provider markers as the installed plugin. OpenCode
    /// JSON output sometimes omits the structured event payload, so preserve a
    /// safe default cooldown when only the marker is available.
    static func freeUsageLimitCooldown(in output: String, nowMilliseconds: Double = Date().timeIntervalSince1970 * 1_000) -> Double? {
        let lowercased = output.lowercased()
        guard lowercased.contains("freeusagelimiterror")
                || lowercased.contains("provider.free-limit")
                || lowercased.contains("free usage limit reached") else { return nil }

        let structured = structuredCooldown(in: output, nowMilliseconds: nowMilliseconds)
        return boundedCooldown(
            structured,
            fallback: defaultCooldownMilliseconds(nowMilliseconds: nowMilliseconds)
        )
    }

    private static func structuredCooldown(in output: String, nowMilliseconds: Double) -> Double? {
        let candidates = [output] + output.split(whereSeparator: \.isNewline).map(String.init)
        for candidate in candidates {
            guard let data = candidate.data(using: .utf8),
                  let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
                  let cooldown = structuredCooldown(in: value, nowMilliseconds: nowMilliseconds, depth: 0) else {
                continue
            }
            return cooldown
        }
        return nil
    }

    private static func structuredCooldown(in value: Any, nowMilliseconds: Double, depth: Int) -> Double? {
        guard depth < 16 else { return nil }
        if let object = value as? [String: Any] {
            for (key, rawValue) in object {
                let normalizedKey = key.lowercased().filter { $0.isLetter || $0.isNumber }
                let number = (rawValue as? NSNumber)?.doubleValue ?? (rawValue as? String).flatMap(Double.init)
                switch normalizedKey {
                case "retryafterms":
                    if let number, number.isFinite, number > 0 { return number }
                case "retryafterseconds", "retryafter":
                    if let number, number.isFinite, number > 0 { return number * 1_000 }
                    if normalizedKey == "retryafter", let date = dateMilliseconds(rawValue) {
                        return date - nowMilliseconds
                    }
                case "resetatms":
                    if let number, number.isFinite { return number - nowMilliseconds }
                case "resetat":
                    if let number, number.isFinite {
                        return (number > 1_000_000_000_000 ? number : number * 1_000) - nowMilliseconds
                    }
                    if let date = dateMilliseconds(rawValue) { return date - nowMilliseconds }
                default:
                    break
                }
            }
            for child in object.values {
                if let cooldown = structuredCooldown(in: child, nowMilliseconds: nowMilliseconds, depth: depth + 1) {
                    return cooldown
                }
            }
        } else if let array = value as? [Any] {
            for child in array {
                if let cooldown = structuredCooldown(in: child, nowMilliseconds: nowMilliseconds, depth: depth + 1) {
                    return cooldown
                }
            }
        } else if let string = value as? String,
                  let data = string.data(using: .utf8),
                  let nested = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) {
            return structuredCooldown(in: nested, nowMilliseconds: nowMilliseconds, depth: depth + 1)
        }
        return nil
    }

    private static func dateMilliseconds(_ value: Any) -> Double? {
        guard let string = value as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        return formatter.date(from: string).map { $0.timeIntervalSince1970 * 1_000 }
    }

    /// OpenCode's free-usage counters reset at 00:00 UTC. When the provider
    /// omits an explicit retry window, wait only until the next UTC midnight
    /// rather than quarantining the proxy for a full 24 hours from now.
    static func defaultCooldownMilliseconds(nowMilliseconds: Double) -> Double {
        let day: Double = 86_400_000
        guard nowMilliseconds.isFinite else { return day }
        let remainder = nowMilliseconds.truncatingRemainder(dividingBy: day)
        let normalized = remainder < 0 ? remainder + day : remainder
        return normalized == 0 ? day : day - normalized
    }

    private static func boundedCooldown(_ milliseconds: Double?, fallback: Double) -> Double {
        guard let milliseconds, milliseconds.isFinite else {
            return min(max(fallback, 1_000), maximumCooldownMs)
        }
        return min(max(milliseconds, 1_000), maximumCooldownMs)
    }

    private static func startIsolatedEdge(
        entry: ProxyEntry,
        proxyURL: String,
        environment: [String: String]
    ) async throws -> ProbeBridge {
        try await Task.detached(priority: .utility) {
            try startIsolatedEdgeSynchronously(entry: entry, proxyURL: proxyURL, environment: environment)
        }.value
    }

    private static func startIsolatedEdgeSynchronously(
        entry: ProxyEntry,
        proxyURL: String,
        environment: [String: String]
    ) throws -> ProbeBridge {
        guard let edgeBinary = locateEdgeBinary(environment: environment),
              let port = freeLoopbackPort() else { throw ProbeSetupError.unavailable }

        let directory = FileManager.default.temporaryDirectory
            .appending(path: "relaydock-quota-probe-\(UUID().uuidString)", directoryHint: .isDirectory)
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)

        var process: Process?
        do {
            let isolatedEntry = ProxyEntry(id: entry.id, label: entry.label, url: proxyURL, enabled: true)
            let isolatedState = ProxyState(mode: .manual, manualId: entry.id, proxies: [isolatedEntry])
            let stateURL = directory.appending(path: "proxies.json")
            try JSONEncoder().encode(isolatedState).write(to: stateURL, options: .atomic)
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stateURL.path)

            let config = EdgeConfigFile(port: port)
            try config.save(to: EdgeConfigFile.fileURL(configDirectory: directory))

            var edgeEnvironment = environment
            edgeEnvironment["RELAYDOCK_CONFIG_DIR"] = directory.path
            for key in ["HTTP_PROXY", "http_proxy", "HTTPS_PROXY", "https_proxy", "ALL_PROXY", "all_proxy",
                        "RELAYDOCK_TEST_PROXY_URL", "RELAYDOCK_TEST_PROXY_ID", "RELAYDOCK_TEST_EDGE_PORT"] {
                edgeEnvironment.removeValue(forKey: key)
            }

            let edgeProcess = Process()
            edgeProcess.executableURL = URL(fileURLWithPath: edgeBinary)
            edgeProcess.arguments = ["run"]
            edgeProcess.environment = edgeEnvironment
            edgeProcess.standardOutput = FileHandle.nullDevice
            edgeProcess.standardError = FileHandle.nullDevice
            try edgeProcess.run()
            process = edgeProcess

            let readyUntil = Date().addingTimeInterval(3)
            var ready = false
            while Date() < readyUntil, edgeProcess.isRunning {
                if let status = EdgeStatusClient.fetchStatus(config: config, timeout: 0.25),
                   status.pid == edgeProcess.processIdentifier {
                    ready = true
                    break
                }
                usleep(100_000)
            }
            guard ready else { throw ProbeSetupError.unavailable }

            let resource = ProbeEdgeResource(process: edgeProcess, directory: directory)
            return ProbeBridge(
                proxyURL: config.proxyURL,
                port: port,
                configDirectory: directory,
                cleanup: { resource.stop() }
            )
        } catch {
            if let process { stop(process) }
            try? manager.removeItem(at: directory)
            throw error
        }
    }

    private static func locateEdgeBinary(environment: [String: String]) -> String? {
        let manager = FileManager.default
        if let override = environment["RELAYDOCK_EDGE_BINARY"], !override.isEmpty {
            return manager.isExecutableFile(atPath: override) ? override : nil
        }

        var candidates: [String] = []
        if let resourceURL = Bundle.main.resourceURL {
            candidates.append(resourceURL.appending(path: "relaydock-edge").path)
        }
        if let executableURL = Bundle.main.executableURL {
            let directory = executableURL.deletingLastPathComponent()
            candidates.append(directory.appending(path: "relaydock-edge").path)
            candidates.append(directory.appending(path: "RelayDockEdge").path)
        }
        let home = environment["HOME"].flatMap { $0.isEmpty ? nil : $0 }
            ?? manager.homeDirectoryForCurrentUser.path
        candidates.append(URL(fileURLWithPath: home, isDirectory: true).appending(path: ".local/bin/relaydock-edge").path)
        for directory in (environment["PATH"] ?? "").split(separator: ":") {
            candidates.append(URL(fileURLWithPath: String(directory), isDirectory: true).appending(path: "relaydock-edge").path)
        }
        return candidates.first(where: manager.isExecutableFile(atPath:))
    }

    private static func freeLoopbackPort() -> Int? {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0 else { return nil }

        var assigned = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let result = withUnsafeMutablePointer(to: &assigned) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
        }
        guard result == 0 else { return nil }
        return Int(UInt16(bigEndian: assigned.sin_port))
    }

    private static func stop(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        let stopUntil = Date().addingTimeInterval(2)
        while process.isRunning, Date() < stopUntil { usleep(50_000) }
        if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
        process.waitUntilExit()
    }

    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Run a login shell so a GUI-launched app sees the same OpenCode install
    /// and PATH the user gets in Terminal. stdout goes to a private temporary
    /// file, avoiding pipe backpressure while the child runs.
    static func runCommand(
        _ command: String,
        _ environment: [String: String],
        _ timeout: TimeInterval
    ) async -> CommandResult {
        await Task.detached(priority: .utility) {
            runCommandSynchronously(command, environment: environment, timeout: timeout)
        }.value
    }

    private static func runCommandSynchronously(
        _ command: String,
        environment: [String: String],
        timeout: TimeInterval
    ) -> CommandResult {
        let manager = FileManager.default
        let outputURL = manager.temporaryDirectory.appending(path: "relaydock-opencode-probe-\(UUID().uuidString).out")
        let errorURL = manager.temporaryDirectory.appending(path: "relaydock-opencode-probe-\(UUID().uuidString).err")
        guard manager.createFile(atPath: outputURL.path, contents: Data(), attributes: [.posixPermissions: 0o600]),
              manager.createFile(atPath: errorURL.path, contents: Data(), attributes: [.posixPermissions: 0o600]),
              let output = try? FileHandle(forWritingTo: outputURL),
              let errorOutput = try? FileHandle(forWritingTo: errorURL) else {
            try? manager.removeItem(at: outputURL)
            try? manager.removeItem(at: errorURL)
            return CommandResult(status: 127, stdout: "", timedOut: false)
        }
        defer {
            try? output.close()
            try? errorOutput.close()
            try? manager.removeItem(at: outputURL)
            try? manager.removeItem(at: errorURL)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lic", command]
        process.environment = environment
        process.standardOutput = output
        process.standardError = errorOutput
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do {
            try process.run()
        } catch {
            return CommandResult(status: 127, stdout: "", timedOut: false)
        }

        let timedOut = exited.wait(timeout: .now() + timeout) != .success
        if timedOut {
            process.terminate()
            if exited.wait(timeout: .now() + 1.5) != .success {
                _ = kill(process.processIdentifier, SIGKILL)
                _ = exited.wait(timeout: .now() + 1.5)
            }
        }
        try? output.synchronize()
        try? errorOutput.synchronize()
        let stdout = (try? Data(contentsOf: outputURL)) ?? Data()
        let stderr = (try? Data(contentsOf: errorURL)) ?? Data()
        var combined = stdout
        if !stderr.isEmpty {
            if !combined.isEmpty { combined.append(0x0A) }
            combined.append(stderr)
        }
        return CommandResult(
            status: timedOut ? 124 : process.terminationStatus,
            stdout: String(decoding: combined, as: UTF8.self),
            timedOut: timedOut
        )
    }

    private enum ProbeSetupError: Error {
        case unavailable
    }

    private final class ProbeEdgeResource: @unchecked Sendable {
        private let process: Process
        private let directory: URL
        private let lock = NSLock()
        private var stopped = false

        init(process: Process, directory: URL) {
            self.process = process
            self.directory = directory
        }

        func stop() {
            lock.lock()
            guard !stopped else {
                lock.unlock()
                return
            }
            stopped = true
            lock.unlock()

            OpenCodeFreeUsageProbe.stop(process)
            try? FileManager.default.removeItem(at: directory)
        }

        deinit { stop() }
    }
}
