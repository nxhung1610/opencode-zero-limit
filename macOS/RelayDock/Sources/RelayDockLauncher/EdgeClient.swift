import Darwin
import Foundation
import RelayDockCore

/// Talks to RelayDock Edge from the launcher: ping the status endpoint, spawn
/// Edge on demand when it is not running, and poll until it is ready. The
/// contract is fail-closed — when anything here throws, the caller refuses to
/// exec the command instead of falling back to a direct launch.
enum EdgeClient {
    struct EdgeUnavailableError: LocalizedError {
        var detail: String
        var errorDescription: String? { detail }
    }

    /// Returns a live status, spawning Edge when the ping fails.
    static func ensureRunning(
        config: EdgeConfigFile,
        environment: [String: String]
    ) throws -> EdgeStatusResponse {
        if let status = EdgeStatusClient.fetchStatus(config: config) { return status }
        // With the launchd agent installed (P2), wake the job and give launchd
        // its start window before falling back to a direct spawn.
        if EdgeLaunchAgent.isInstalled(environment: environment) {
            let configDirectory = EdgeConfigFile.fileURL(environment: environment).deletingLastPathComponent()
            if EdgeLaunchAgent.activate(configDirectory: configDirectory, environment: environment) {
                let agentDeadline = Date().addingTimeInterval(1.5)
                while Date() < agentDeadline {
                    Thread.sleep(forTimeInterval: 0.15)
                    if let status = EdgeStatusClient.fetchStatus(config: config, timeout: 0.5) { return status }
                }
            }
        }
        try spawnEdge(environment: environment)
        let deadline = Date().addingTimeInterval(3.0)
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 0.15)
            if let status = EdgeStatusClient.fetchStatus(config: config, timeout: 0.5) { return status }
        }
        let logURL = EdgeConfigFile.fileURL(environment: environment)
            .deletingLastPathComponent()
            .appending(path: "edge.log")
        throw EdgeUnavailableError(
            detail: "RelayDock Edge did not become ready on 127.0.0.1:\(config.port) (see \(logURL.path))."
        )
    }

    /// Spawns Edge fully detached: a fresh session (`POSIX_SPAWN_SETSID`) and
    /// every inherited descriptor closed at exec (`POSIX_SPAWN_CLOEXEC_DEFAULT`
    /// with /dev/null stdio), so a piped wrapper never leaves Edge holding the
    /// terminal or a user pipe open.
    static func spawnEdge(environment: [String: String]) throws {
        let executable = try locateEdgeBinary(environment: environment)

        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        posix_spawn_file_actions_addopen(&fileActions, 0, "/dev/null", O_RDWR, 0)
        posix_spawn_file_actions_addopen(&fileActions, 1, "/dev/null", O_RDWR, 0)
        posix_spawn_file_actions_addopen(&fileActions, 2, "/dev/null", O_RDWR, 0)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))

        var argv: [UnsafeMutablePointer<CChar>?] = [strdup(executable), nil]
        var envp: [UnsafeMutablePointer<CChar>?] = environment.map { strdup("\($0.key)=\($0.value)") }
        envp.append(nil)
        defer {
            for pointer in argv where pointer != nil { free(pointer) }
            for pointer in envp where pointer != nil { free(pointer) }
        }

        var pid = pid_t()
        let result = posix_spawn(&pid, executable, &fileActions, &attributes, &argv, &envp)
        guard result == 0 else {
            let reason = strerror(result).flatMap { String(validatingCString: $0) } ?? "error \(result)"
            throw EdgeUnavailableError(detail: "RelayDock could not start Edge (\(reason)).")
        }
    }

    /// Finds the edge binary: `RELAYDOCK_EDGE_BINARY` override, then a sibling
    /// of the launcher's own executable (how the installer lays it out), then
    /// `PATH`.
    static func locateEdgeBinary(environment: [String: String]) throws -> String {
        let manager = FileManager.default
        if let override = environment["RELAYDOCK_EDGE_BINARY"], !override.isEmpty {
            guard manager.isExecutableFile(atPath: override) else {
                throw EdgeUnavailableError(
                    detail: "RELAYDOCK_EDGE_BINARY points at \(override), which is not executable."
                )
            }
            return override
        }
        if let own = Launcher.ownExecutablePath() {
            let sibling = URL(fileURLWithPath: own)
                .deletingLastPathComponent()
                .appending(path: "relaydock-edge")
                .path
            if manager.isExecutableFile(atPath: sibling) { return sibling }
        }
        let pathValue = environment["PATH"] ?? "/usr/local/bin:/usr/bin:/bin"
        for directory in pathValue.split(separator: ":", omittingEmptySubsequences: true) {
            let candidate = URL(fileURLWithPath: String(directory), isDirectory: true)
                .appending(path: "relaydock-edge")
                .path
            if manager.isExecutableFile(atPath: candidate) { return candidate }
        }
        throw EdgeUnavailableError(
            detail: "relaydock-edge was not found next to the wrapper or in PATH. "
                + "Run scripts/opencode-wrapper.sh install."
        )
    }
}
