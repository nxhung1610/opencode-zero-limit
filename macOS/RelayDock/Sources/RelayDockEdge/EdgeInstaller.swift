import Foundation
import RelayDockCore

/// The `relaydock-edge install|uninstall` orchestration: the steps
/// `scripts/opencode-wrapper.sh` used to run in bash, moved into the binary so
/// the wrapper script and the app share one implementation and one test
/// surface. Every path derives from `environment` — `HOME`, `PATH`,
/// `RELAYDOCK_CONFIG_DIR`, `RELAYDOCK_LAUNCHCTL` — so tests and the sandbox
/// never touch the real login session or user data.
struct EdgeInstaller {
    var environment: [String: String]
    /// How long `install` waits for Edge to report ready after bootstrap.
    var statusWait: TimeInterval = 6
    /// Status probe seam; tests replace it so no sockets are involved.
    var statusProbe: (EdgeConfigFile) -> Bool = { EdgeStatusClient.fetchStatus(config: $0) != nil }
    /// Stops a previously installed Edge before its binary is replaced or
    /// removed (`<installed edge> stop`, best effort). Seam for tests.
    var stopInstalledEdge: (URL) -> Void = EdgeInstaller.stopHelper
    var stdout: (String) -> Void = { print($0) }
    var stderr: (String) -> Void = { message in
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
    var sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
    var now: () -> Date = { Date() }

    // MARK: - Paths

    private var home: URL {
        if let value = environment["HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !value.isEmpty {
            return URL(fileURLWithPath: value, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    private var binDirectory: URL {
        home.appending(path: ".local/bin", directoryHint: .isDirectory)
    }

    private var installedLauncher: URL { binDirectory.appending(path: "relaydock-launch") }
    private var installedEdge: URL { binDirectory.appending(path: "relaydock-edge") }
    private var commandLink: URL { binDirectory.appending(path: "opencode") }
    private var configDirectory: URL { EdgeConfigFile.configDirectory(environment: environment) }
    private var edgeConfig: URL { configDirectory.appending(path: "edge.json") }
    private var agentPlist: URL { EdgeLaunchAgent.plistURL(environment: environment) }

    // MARK: - Install

    func install(sourceLauncher: URL, sourceEdge: URL) -> Int32 {
        let manager = FileManager.default
        do {
            try manager.createDirectory(at: binDirectory, withIntermediateDirectories: true)
        } catch {
            stderr("relaydock-edge: could not create \(binDirectory.path): \(error.localizedDescription)")
            return 1
        }
        if !isSymlink(commandLink), manager.fileExists(atPath: commandLink.path) {
            stderr("Refusing to replace \(commandLink.path): it exists and is not a symlink.")
            return 1
        }
        // Upgrade path: stop a stale instance so the new binary takes over.
        // With the launchd agent this also unloads the job; installAgent
        // re-arms it with the fresh binary. Nothing to stop on a cold
        // install — not an error.
        if manager.isExecutableFile(atPath: installedEdge.path) {
            stopInstalledEdge(installedEdge)
        }
        do {
            try installFile(source: sourceLauncher, destination: installedLauncher)
            try installFile(source: sourceEdge, destination: installedEdge)
            try? manager.removeItem(at: commandLink)
            try manager.createSymbolicLink(at: commandLink, withDestinationURL: installedLauncher)
        } catch {
            stderr("relaydock-edge: install failed: \(error.localizedDescription)")
            return 1
        }
        switch EdgeMain.ensureInitialized(environment: environment) {
        case .kept(_, let config):
            stdout("edge.json already configured (port \(config.port)); keeping it.")
        case .wrote(let configURL, let config):
            stdout("Wrote \(configURL.path) — port \(config.port)")
        case .failure(let message):
            stderr(message)
            return 1
        }
        installAgent()
        stdout("Installed \(commandLink.path) -> \(installedLauncher.path)")
        stdout("Installed \(installedEdge.path)")
        reportPathOrder()
        stdout(Self.hintText)
        return 0
    }

    /// Writes the launchd agent plist (contents from `EdgeMain.agentPlist`,
    /// baked for the *installed* executable), loads it, and waits for Edge to
    /// report ready. Every failure here is a warning: the next wrapped launch
    /// falls back to spawning Edge on demand, so setup still works.
    private func installAgent() {
        guard let plist = EdgeMain.agentPlist(environment: environment, executablePath: installedEdge.path) else {
            stderr("Warning: could not generate \(agentPlist.path); Edge will be spawned on demand.")
            return
        }
        do {
            try FileManager.default.createDirectory(
                at: agentPlist.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: agentPlist, options: .atomic)
        } catch {
            try? FileManager.default.removeItem(at: agentPlist)
            stderr("Warning: could not generate \(agentPlist.path); Edge will be spawned on demand.")
            return
        }
        _ = EdgeLaunchAgent.bootout(environment: environment)
        guard EdgeLaunchAgent.bootstrap(environment: environment) else {
            stderr("Warning: could not load \(agentPlist.path) (no login session?); Edge will be spawned on demand.")
            return
        }
        let config = EdgeConfigFile.load(from: edgeConfig)
        func ready() -> Bool { config.map(statusProbe) ?? false }
        let deadline = now().addingTimeInterval(statusWait)
        var isReady = ready()
        while !isReady, now() < deadline {
            sleep(0.25)
            isReady = ready()
        }
        if isReady {
            stdout("Edge is running under launchd agent \(EdgeLaunchAgent.label)")
        } else {
            stderr(
                "Warning: \(EdgeLaunchAgent.label) is loaded but Edge has not reported ready; "
                + "see \(configDirectory.path)/edge.log"
            )
        }
    }

    // MARK: - Uninstall

    func uninstall() -> Int32 {
        let manager = FileManager.default
        // Unload the agent before removing the binary: while the job stays
        // loaded, launchd would keep respawning an Edge whose executable is
        // gone.
        if manager.fileExists(atPath: agentPlist.path) {
            _ = EdgeLaunchAgent.bootout(environment: environment)
            try? manager.removeItem(at: agentPlist)
            stdout("Removed launchd agent \(agentPlist.path)")
        }
        if manager.isExecutableFile(atPath: installedEdge.path) {
            stopInstalledEdge(installedEdge)
        }
        if isSymlink(commandLink) {
            try? manager.removeItem(at: commandLink)
            stdout("Removed \(commandLink.path)")
        } else {
            stdout("No wrapper symlink at \(commandLink.path)")
        }
        if manager.fileExists(atPath: installedLauncher.path) {
            try? manager.removeItem(at: installedLauncher)
            stdout("Removed \(installedLauncher.path)")
        }
        if manager.fileExists(atPath: installedEdge.path) {
            try? manager.removeItem(at: installedEdge)
            stdout("Removed \(installedEdge.path)")
        }
        if manager.fileExists(atPath: edgeConfig.path) {
            try? manager.removeItem(at: edgeConfig)
            stdout("Removed \(edgeConfig.path)")
        }
        stdout("Kept the proxy pool and Edge script cache (user data) in: \(configDirectory.path)")
        return 0
    }

    // MARK: - Helpers

    private func installFile(source: URL, destination: URL) throws {
        let manager = FileManager.default
        if source.standardizedFileURL == destination.standardizedFileURL { return }
        try? manager.removeItem(at: destination)
        try manager.copyItem(at: source, to: destination)
        try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path)
    }

    private func isSymlink(_ url: URL) -> Bool {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil
    }

    /// Mirrors the script's PATH checks: the bin directory must be in PATH,
    /// and an earlier `opencode` wins over the wrapper.
    private func reportPathOrder() {
        let binPath = binDirectory.path
        if !(":" + (environment["PATH"] ?? "") + ":").contains(":" + binPath + ":") {
            stderr("Notice: \(binPath) is not in PATH; add it so the wrapper is found.")
        }
        guard let resolved = resolveExecutable(named: "opencode") else { return }
        if URL(fileURLWithPath: resolved).standardizedFileURL == commandLink.standardizedFileURL {
            stdout("OK: 'opencode' resolves to the wrapper.")
        } else {
            stderr(
                "Notice: 'opencode' resolves to \(resolved) — an earlier PATH entry wins, "
                + "so the wrapper will not intercept launches until PATH order changes."
            )
        }
    }

    private func resolveExecutable(named name: String) -> String? {
        let manager = FileManager.default
        for entry in (environment["PATH"] ?? "").split(separator: ":", omittingEmptySubsequences: true) {
            let candidate = URL(fileURLWithPath: String(entry), isDirectory: true).appending(path: name)
            var isDirectory: ObjCBool = false
            guard manager.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue,
                  manager.isExecutableFile(atPath: candidate.path) else { continue }
            return candidate.path
        }
        return nil
    }

    /// `<installed edge> stop`, detached and quiet, like the script's
    /// `"$INSTALLED_EDGE" stop >/dev/null 2>&1 || true`. Internal (not
    /// private) so it can be a default argument value.
    static func stopHelper(_ executable: URL) {
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { return }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["stop"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }

    /// The closing HINT block, verbatim from `scripts/opencode-wrapper.sh`.
    static let hintText = """

    Apply routing to OpenCode's background service (it performs model calls):
      opencode service stop && opencode service start   # interrupts active sessions

    Inspect Edge and a launch:
      relaydock-edge status
      ps eww -p <opencode pid> | tr ' ' '\\n' | grep -i proxy
      lsof -nP -iTCP -a -p <opencode pid> | grep ESTABLISHED

    The wrapper sets the environment; the app's Edge panel reports the tunnels
    Edge actually served. Direct traffic stays invisible.
    """
}
