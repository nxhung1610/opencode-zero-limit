import Darwin
import Foundation
import RelayDockCore

/// The PATH wrapper: runs a command (normally `opencode`) with the proxy
/// environment selected by RelayDock.
///
/// Invoke it under its own name with the command to run
/// (`relaydock-launch opencode …`) or symlink it as the command name
/// (`~/.local/bin/opencode`). In the symlink form the launcher finds the real
/// command in `PATH`, skipping itself, so the wrapped command keeps working.
enum Launcher {
    static let binaryNames: Set<String> = ["relaydock-launch", "RelayDockLauncher"]

    // MARK: - Entry point

    static func run(commandLineArguments: [String], environment: [String: String]) -> Never {
        let invocationPath = commandLineArguments.first ?? ""
        let rest = Array(commandLineArguments.dropFirst())
        let basename = URL(fileURLWithPath: invocationPath).lastPathComponent
        let explicitInvocation = binaryNames.contains(basename)

        if explicitInvocation, let first = rest.first, first == "--help" || first == "-h" {
            printUsage()
            exit(0)
        }

        let target: (command: String, arguments: [String])
        do {
            target = try targetCommand(invocationPath: invocationPath, arguments: rest)
        } catch {
            printUsage(to: .standardError)
            exit(2)
        }

        let pathValue = environment["PATH"] ?? "/usr/local/bin:/usr/bin:/bin"
        var ownPaths: [String] = []
        if let own = ownExecutablePath() {
            ownPaths.append(own)
        }
        if invocationPath.contains("/") {
            ownPaths.append(resolvedPath(invocationPath))
        }
        guard let executable = findExecutable(named: target.command, pathValue: pathValue, skipping: ownPaths) else {
            fail(LauncherError.commandNotFound(target.command).localizedDescription)
        }

        let store = ProxyStore(environment: environment)
        let state: ProxyState
        do {
            state = try store.load()
        } catch {
            fail(error.localizedDescription)
        }

        // Every launch is a fresh process, so the in-memory script cache cannot
        // bridge launches on its own. Persist it next to proxies.json: without
        // the file a script that caches its proxy would call its provider on
        // every launch and trip provider rate limits.
        let cacheFileURL = store.fileURL.deletingLastPathComponent().appending(path: "launcher-cache.json")
        importProxyScriptCacheSnapshots(LauncherCacheFile.load(from: cacheFileURL).snapshots(matching: state))

        let proxyURL: String?
        do {
            proxyURL = try store.selectForSpawn()
        } catch {
            fail("\(error.localizedDescription) \(target.command) was not started; fix the proxy pool or switch the mode to Off in RelayDock.")
        }
        try? LauncherCacheFile.make(snapshots: exportProxyScriptCacheSnapshots(), state: state).save(to: cacheFileURL)

        if environment["RELAYDOCK_QUIET"] != "1" {
            writeError(statusLine(proxyURL: proxyURL, store: store))
        }

        replaceProcess(
            executable: executable,
            arguments: [executable] + target.arguments,
            environment: buildOpenCodeProxyEnvironment(proxyURL: proxyURL, base: environment)
        )
    }

    // MARK: - Process replacement

    /// Replaces the launcher process with the command, the way a shell starts
    /// a job: the command keeps the launcher's pid and process group, so
    /// terminal job control, signals, and Ctrl+C behave exactly as if the
    /// wrapper were not there. A plain child process would land in its own
    /// process group and be SIGTTIN-stopped the moment a full-screen TUI
    /// reads the terminal.
    private static func replaceProcess(executable: String, arguments: [String], environment: [String: String]) -> Never {
        var argv = arguments.map { strdup($0) }
        argv.append(nil)
        var envp = environment.map { strdup("\($0.key)=\($0.value)") }
        envp.append(nil)
        execve(executable, argv, envp)
        // execve only returns when it fails.
        let reason = strerror(errno).flatMap { String(validatingCString: $0) } ?? "unknown error"
        fail("could not run \(executable): \(reason)", code: 127)
    }

    // MARK: - Invocation

    /// Resolves the command from how the launcher was invoked. Under its own
    /// name the first argument names the command; under any other name (a
    /// symlinked wrapper) the invocation name is the command.
    static func targetCommand(invocationPath: String, arguments: [String]) throws -> (command: String, arguments: [String]) {
        let basename = URL(fileURLWithPath: invocationPath).lastPathComponent
        if binaryNames.contains(basename) {
            guard let command = arguments.first, !command.isEmpty else {
                throw LauncherError.usage
            }
            return (command, Array(arguments.dropFirst()))
        }
        return (basename, arguments)
    }

    /// Finds `name` in `PATH` (or an explicit path containing `/`), skipping
    /// any candidate that is the launcher itself so a wrapper symlinked as the
    /// command never re-invokes itself.
    static func findExecutable(named name: String, pathValue: String, skipping ownPaths: [String]) -> String? {
        let manager = FileManager.default

        func isLauncherItself(_ candidate: String) -> Bool {
            let resolved = resolvedPath(candidate)
            if ownPaths.contains(resolved) {
                return true
            }
            return ownPaths.contains { sameFile(resolved, $0) }
        }

        if name.contains("/") {
            let candidate = URL(fileURLWithPath: name).standardizedFileURL.path
            guard manager.isExecutableFile(atPath: candidate), !isLauncherItself(candidate) else { return nil }
            return candidate
        }

        for directory in pathValue.split(separator: ":", omittingEmptySubsequences: true) {
            let candidate = URL(fileURLWithPath: String(directory), isDirectory: true)
                .appending(path: name)
                .path
            guard manager.isExecutableFile(atPath: candidate), !isLauncherItself(candidate) else { continue }
            return candidate
        }
        return nil
    }

    /// The launcher's own real path. `_NSGetExecutablePath` always describes
    /// the running binary, whatever name `PATH` resolved it under.
    static func ownExecutablePath() -> String? {
        var size: UInt32 = 0
        _NSGetExecutablePath(nil, &size)
        if size > 0 {
            var buffer = [CChar](repeating: 0, count: Int(size))
            if _NSGetExecutablePath(&buffer, &size) == 0 {
                let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
                let path = String(decoding: bytes, as: UTF8.self)
                if !path.isEmpty {
                    return resolvedPath(path)
                }
            }
        }
        if let executablePath = Bundle.main.executablePath, !executablePath.isEmpty {
            return resolvedPath(executablePath)
        }
        return nil
    }

    static func resolvedPath(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// True when two paths refer to the same file (device and inode), so a
    /// candidate that is the launcher under another name is never run as the
    /// wrapped command.
    static func sameFile(_ firstPath: String, _ secondPath: String) -> Bool {
        let manager = FileManager.default
        guard let first = try? manager.attributesOfItem(atPath: firstPath),
              let second = try? manager.attributesOfItem(atPath: secondPath),
              let firstInode = first[.systemFileNumber] as? NSNumber,
              let secondInode = second[.systemFileNumber] as? NSNumber,
              let firstDevice = first[.systemNumber] as? NSNumber,
              let secondDevice = second[.systemNumber] as? NSNumber else {
            return false
        }
        return firstInode == secondInode && firstDevice == secondDevice
    }

    // MARK: - Output

    /// What the launcher reports on stderr before starting the command. It
    /// names the environment it configured — it cannot verify the child's
    /// traffic.
    static func statusLine(proxyURL: String?, store: ProxyStore) -> String {
        guard let proxyURL else {
            return "RelayDock: proxy mode is Off — launching without a proxy"
        }
        var label: String?
        if let latest = try? store.load() {
            let selectedID = latest.mode == .manual ? latest.manualId : latest.bindings["default"]
            label = selectedID.flatMap { id in latest.proxies.first { $0.id == id }?.label }
        }
        let target = maskedProxyURL(proxyURL)
        if let label, !label.isEmpty {
            return "RelayDock: routed via \(label) (\(target))"
        }
        return "RelayDock: routed via \(target)"
    }

    private static let usageText = """
    RelayDock launcher — runs a command with the RelayDock-selected proxy.

    Usage:
      relaydock-launch <command> [arguments...]
      or symlink the launcher as the command name (for example
      ~/.local/bin/opencode) and invoke the command normally.

    The command runs with the proxy environment RelayDock selects. Off mode
    runs it without a proxy; Manual and Auto selection errors stop the launch.
    Set RELAYDOCK_QUIET=1 to suppress the routing line.
    """

    private static func writeError(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }

    private static func fail(_ message: String, code: Int32 = 1) -> Never {
        writeError("RelayDock: " + message)
        exit(code)
    }

    private static func printUsage(to handle: FileHandle = .standardOutput) {
        handle.write(Data((usageText + "\n").utf8))
    }
}

enum LauncherError: LocalizedError {
    case usage
    case commandNotFound(String)

    var errorDescription: String? {
        switch self {
        case .usage:
            "Usage: relaydock-launch <command> [arguments...]"
        case .commandNotFound(let command):
            "\(command) was not found in PATH."
        }
    }
}
