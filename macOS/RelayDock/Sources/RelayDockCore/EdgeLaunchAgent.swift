import Darwin
import Foundation

/// The per-user launchd agent that supervises RelayDock Edge (P2 lifecycle).
///
/// The installer (`relaydock-edge install`, which `scripts/opencode-wrapper.sh`
/// delegates to) writes `~/Library/LaunchAgents/<label>.plist` and bootstraps
/// it. Once loaded,
/// launchd starts Edge at login (`RunAtLoad`) and restarts it after abnormal
/// exits (`KeepAlive`/`SuccessfulExit`), so consumers stop racing cold starts:
/// the launcher kickstarts the job when its ping fails, and
/// `relaydock-edge stop` boots the job out.
///
/// Exactly one config directory is managed at a time: the plist bakes
/// `RELAYDOCK_CONFIG_DIR` when the install used an override. `manages(...)`
/// refuses to kickstart or bootout a job whose directory does not match the
/// caller's, so sandboxed or secondary configs can never fight the real
/// login-session agent.
///
/// The `RELAYDOCK_LAUNCHCTL` environment override points at a different
/// launchctl binary (tests only, mirroring `RELAYDOCK_EDGE_BINARY`).
public enum EdgeLaunchAgent {
    /// Keep in sync with `scripts/opencode-wrapper.sh` (a unit test pins this).
    public static let label = "com.nxhung.relaydock.edge"

    /// `~/Library/LaunchAgents/<label>.plist`. Honors `HOME` so tests and
    /// sandboxes stay off the real login session.
    public static func plistURL(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        let homePath = environment["HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let home = homePath.flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser
        return home.appending(path: "Library/LaunchAgents", directoryHint: .isDirectory)
            .appending(path: "\(label).plist")
    }

    public static func isInstalled(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        FileManager.default.fileExists(atPath: plistURL(environment: environment).path)
    }

    /// True when the installed plist declares launchd `Sockets` (P3 socket
    /// activation): launchd holds the loopback listener and starts Edge on
    /// the first connection, so a failing ping is a wake signal rather than
    /// evidence of a dead process.
    public static func usesSocketActivation(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        let url = plistURL(environment: environment)
        guard let data = try? Data(contentsOf: url),
              let plist = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil))
                  as? [String: Any],
              let sockets = plist["Sockets"] as? [String: Any] else { return false }
        return !sockets.isEmpty
    }

    /// The config directory the installed plist manages: its baked
    /// `RELAYDOCK_CONFIG_DIR`, or the default app-support directory for the
    /// environment's `HOME` when the plist bakes no override.
    public static func managedConfigDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        let url = plistURL(environment: environment)
        if let data = try? Data(contentsOf: url),
           let plist = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil))
               as? [String: Any],
           let environmentVariables = plist["EnvironmentVariables"] as? [String: Any],
           let baked = environmentVariables["RELAYDOCK_CONFIG_DIR"] as? String,
           !baked.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return URL(fileURLWithPath: baked, isDirectory: true).standardizedFileURL
        }
        var defaultEnvironment = environment
        defaultEnvironment.removeValue(forKey: "RELAYDOCK_CONFIG_DIR")
        return EdgeConfigFile.configDirectory(environment: defaultEnvironment)
    }

    /// True when the installed plist exists and manages exactly `configDirectory`.
    public static func manages(
        configDirectory: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        guard isInstalled(environment: environment) else { return false }
        return managedConfigDirectory(environment: environment).standardizedFileURL
            == configDirectory.standardizedFileURL
    }

    public static func isLoaded(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        runLaunchctl(["print", launchdServiceTarget], environment: environment) == 0
    }

    /// Makes the agent's Edge run: kickstart when the job is loaded, bootstrap
    /// when the plist is installed but not loaded. Returns false when the
    /// agent does not manage `configDirectory` or launchctl failed — callers
    /// fall back to spawning Edge directly.
    @discardableResult
    public static func activate(
        configDirectory: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        guard manages(configDirectory: configDirectory, environment: environment) else { return false }
        if isLoaded(environment: environment) {
            return runLaunchctl(["kickstart", "-k", launchdServiceTarget], environment: environment) == 0
        }
        return bootstrap(environment: environment)
    }

    /// Loads the job from the installed plist. The installer's path: the
    /// plist was just written, so there is nothing loaded to kickstart.
    @discardableResult
    public static func bootstrap(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        runLaunchctl(
            ["bootstrap", "gui/\(getuid())", plistURL(environment: environment).path],
            environment: environment
        ) == 0
    }

    /// Unloads the job. The plist file stays in place; the next wrapped launch
    /// re-arms the agent.
    @discardableResult
    public static func bootout(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        runLaunchctl(["bootout", launchdServiceTarget], environment: environment) == 0
    }

    private static var launchdServiceTarget: String { "gui/\(getuid())/\(label)" }

    /// Runs launchctl detached from any terminal (stdio to `/dev/null`) and
    /// waits for it, mirroring the Edge spawn. The child gets exactly
    /// `environment`, so tests can point `RELAYDOCK_LAUNCHCTL` at a fake and
    /// keep the real login session untouched.
    private static func runLaunchctl(_ arguments: [String], environment: [String: String]) -> Int32 {
        let executable = environment["RELAYDOCK_LAUNCHCTL"] ?? "/bin/launchctl"

        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        posix_spawn_file_actions_addopen(&fileActions, 0, "/dev/null", O_RDWR, 0)
        posix_spawn_file_actions_addopen(&fileActions, 1, "/dev/null", O_RDWR, 0)
        posix_spawn_file_actions_addopen(&fileActions, 2, "/dev/null", O_RDWR, 0)

        var argv: [UnsafeMutablePointer<CChar>?] = ([executable] + arguments).map { strdup($0) }
        argv.append(nil)
        var envp: [UnsafeMutablePointer<CChar>?] = environment.map { strdup("\($0.key)=\($0.value)") }
        envp.append(nil)
        defer {
            for pointer in argv where pointer != nil { free(pointer) }
            for pointer in envp where pointer != nil { free(pointer) }
        }

        var pid = pid_t()
        let result = posix_spawn(&pid, executable, &fileActions, nil, &argv, &envp)
        guard result == 0 else { return result }

        var waitStatus: Int32 = 0
        while waitpid(pid, &waitStatus, 0) == -1, errno == EINTR {}
        guard (waitStatus & 0x7F) == 0 else { return waitStatus }
        return (waitStatus >> 8) & 0xFF
    }
}
