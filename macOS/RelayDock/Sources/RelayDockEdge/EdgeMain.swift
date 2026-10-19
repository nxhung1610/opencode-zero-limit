import Darwin
import Foundation
import RelayDockCore

@main
struct EdgeMain {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        let environment = ProcessInfo.processInfo.environment
        let command = arguments.first ?? "run"
        switch command {
        case "run":
            runDaemon(environment: environment)
        case "init":
            runInit(environment: environment)
        case "stop":
            runStop(environment: environment)
        case "status":
            runStatus(environment: environment)
        case "agent-plist":
            runAgentPlist(environment: environment)
        case "install":
            runInstall(arguments: Array(arguments.dropFirst()), environment: environment)
        case "uninstall":
            runUninstall(environment: environment)
        case "--help", "-h", "help":
            print(usageText)
            exit(0)
        default:
            FileHandle.standardError.write(Data("relaydock-edge: unknown command '\(command)'\n\(usageText)\n".utf8))
            exit(2)
        }
    }

    static let usageText = """
    Usage: relaydock-edge [run|init|stop|status|agent-plist|install|uninstall]

      run          Run the daemon (default); reads edge.json next to proxies.json.
      init         Write edge.json with a free port (installer).
      stop         Stop Edge: unloads the launchd agent when it manages this
                   install, otherwise asks the running instance to shut down.
      status       Print the live status JSON (exit 1 when not running).
      agent-plist  Print the launchd agent plist for this install (installer).
      install      Install the PATH wrapper for this user (installer). The
                   launcher binary defaults to a sibling `relaydock-launch`;
                   override with --launcher <path>.
      uninstall    Remove the wrapper: launchd agent, both binaries, the
                   `opencode` symlink, and edge.json. User data stays.
    """

    // MARK: - Daemon

    static func runDaemon(environment: [String: String]) -> Never {
        // Detach from any controlling terminal. When the launcher spawns Edge
        // it already requests POSIX_SPAWN_SETSID and this call is a no-op.
        _ = setsid()
        signal(SIGHUP, SIG_IGN)
        signal(SIGPIPE, SIG_IGN)

        let configURL = EdgeConfigFile.fileURL(environment: environment)
        guard let config = EdgeConfigFile.load(from: configURL) else {
            let message = "relaydock-edge: edge.json is missing or invalid at \(configURL.path); "
                + "run scripts/opencode-wrapper.sh install\n"
            FileHandle.standardError.write(Data(message.utf8))
            exit(1)
        }
        let directory = configURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        let log = EdgeLog(url: directory.appending(path: "edge.log"))
        log.info("boot: pid \(getpid()), port \(config.port), config directory \(directory.path)")

        let listenerReport = EdgeListenerReport()
        let daemon = EdgeDaemon(config: config, directory: directory, log: log, listenerReport: listenerReport)
        var servers: [EdgeServer] = []
        do {
            servers.append(try EdgeServer(
                config: config, daemon: daemon, log: log,
                role: .primary, listenerReport: listenerReport
            ))
        } catch {
            log.error("boot: \(error.localizedDescription)")
            exit(1)
        }
        for (index, listener) in config.listeners.enumerated() {
            guard let port = UInt16(exactly: listener.port) else {
                log.warn("listener: port \(listener.port) is out of range; skipping")
                continue
            }
            do {
                servers.append(try EdgeServer(
                    config: config, daemon: daemon, log: log,
                    role: .pinned(entryID: listener.entryID),
                    port: port,
                    activationName: EdgeSocketActivation.listenerName(index: index),
                    listenerReport: listenerReport
                ))
            } catch {
                log.warn(
                    "listener: could not open 127.0.0.1:\(listener.port) for \(listener.entryID) "
                    + "(\(error.localizedDescription)); skipping"
                )
            }
        }

        var signalSources: [DispatchSourceSignal] = []
        for signalNumber in [SIGTERM, SIGINT] {
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
            signal(signalNumber, SIG_IGN)
            source.setEventHandler {
                log.info("shutdown: signal \(signalNumber)")
                log.flush()
                exit(0)
            }
            source.resume()
            signalSources.append(source)
        }

        for server in servers { server.start() }

        // `dispatchMain()` never returns; without this, the release optimizer
        // may release the servers (and the signal sources) at their last use,
        // leaving a bound port whose handlers are silent no-ops.
        withExtendedLifetime((servers, signalSources)) {
            dispatchMain()
        }
    }

    // MARK: - Init

    /// What `ensureInitialized` produced. Shared by the `init` command and the
    /// installer, which must not shell out to itself for this.
    enum InitOutcome {
        case kept(configURL: URL, config: EdgeConfigFile)
        case wrote(configURL: URL, config: EdgeConfigFile)
        case failure(String)
    }

    /// Loads `edge.json`, or writes a fresh one with a free loopback port.
    /// On upgrades the existing file is kept — the port never renumbers once
    /// consumers hold it.
    static func ensureInitialized(environment: [String: String]) -> InitOutcome {
        let configURL = EdgeConfigFile.fileURL(environment: environment)
        if let existing = EdgeConfigFile.load(from: configURL) {
            return .kept(configURL: configURL, config: existing)
        }
        guard let port = EdgePortProbe.firstFreePort(startingAt: EdgeConfigFile.defaultPort, attempts: 20) else {
            return .failure("relaydock-edge: no free loopback port found near \(EdgeConfigFile.defaultPort).")
        }
        let config = EdgeConfigFile(port: port)
        do {
            try config.save(to: configURL)
        } catch {
            return .failure("relaydock-edge: could not write \(configURL.path): \(error.localizedDescription)")
        }
        return .wrote(configURL: configURL, config: config)
    }

    static func runInit(environment: [String: String]) -> Never {
        switch ensureInitialized(environment: environment) {
        case .kept(_, let config):
            print("edge.json already configured (port \(config.port)); keeping it.")
            exit(0)
        case .wrote(let configURL, let config):
            print("Wrote \(configURL.path) — port \(config.port)")
            exit(0)
        case .failure(let message):
            FileHandle.standardError.write(Data((message + "\n").utf8))
            exit(1)
        }
    }

    // MARK: - Stop

    static func runStop(environment: [String: String]) -> Never {
        // The launchd agent (P2) owns Edge's lifecycle when it is installed
        // for this config directory: unload the job — the plist stays, and
        // the next wrapped launch re-arms it. A plain shutdown request would
        // leave a loaded job ready to respawn Edge, so bootout is the only
        // honest way to stop a managed Edge.
        let configDirectory = EdgeConfigFile.fileURL(environment: environment).deletingLastPathComponent()
        if EdgeLaunchAgent.manages(configDirectory: configDirectory, environment: environment),
           EdgeLaunchAgent.isLoaded(environment: environment) {
            guard EdgeLaunchAgent.bootout(environment: environment) else {
                FileHandle.standardError.write(Data(
                    "relaydock-edge: could not unload the launchd agent \(EdgeLaunchAgent.label).\n".utf8
                ))
                exit(1)
            }
            print("Stopped RelayDock Edge (unloaded launchd agent \(EdgeLaunchAgent.label)).")
            print("The agent plist stays in place; the next wrapped launch re-arms it.")
            exit(0)
        }
        let configURL = EdgeConfigFile.fileURL(environment: environment)
        guard let config = EdgeConfigFile.load(from: configURL) else {
            print("RelayDock Edge is not configured; nothing to stop.")
            exit(0)
        }
        guard EdgeStatusClient.fetchStatus(config: config) != nil else {
            print("RelayDock Edge is not running.")
            exit(0)
        }
        _ = EdgeStatusClient.requestShutdown(config: config)
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if EdgeStatusClient.fetchStatus(config: config, timeout: 0.3) == nil { break }
            Thread.sleep(forTimeInterval: 0.1)
        }
        if EdgeStatusClient.fetchStatus(config: config, timeout: 0.3) == nil {
            print("Stopped RelayDock Edge.")
            exit(0)
        }
        FileHandle.standardError.write(Data("relaydock-edge: the running instance did not stop in time.\n".utf8))
        exit(1)
    }

    // MARK: - Agent plist

    /// The launchd agent property list. Pure so tests can pin its shape.
    ///
    /// `KeepAlive` uses `SuccessfulExit: false` rather than the plain `true`:
    /// launchd restarts Edge after crashes, but a deliberate quiet exit — the
    /// port-conflict loser path exits 0 — must not respawn-loop while a
    /// manually spawned Edge holds the port.
    ///
    /// `Sockets` (P3) hands the loopback listeners to launchd: it holds them
    /// across Edge restarts and starts Edge on the first connection, so no
    /// consumer races a cold start and the port can never be taken by a
    /// foreign process. With sockets declared, `RunAtLoad` stays false — Edge
    /// exists only while it has traffic. Without an `edge.json` (a hand-rolled
    /// setup that skipped `init`), the classic RunAtLoad-only job is emitted.
    /// `executablePath` bakes the binary the agent runs: the installer passes
    /// the *installed* path, while the `agent-plist` command defaults to this
    /// process's own executable.
    static func agentPlist(environment: [String: String], executablePath: String? = nil) -> [String: Any]? {
        guard let executable = executablePath ?? ownExecutablePath() else { return nil }
        let configDirectory = EdgeConfigFile.configDirectory(environment: environment)
        let agentLog = configDirectory.appending(path: "edge-agent.log").path
        var plist: [String: Any] = [
            "Label": EdgeLaunchAgent.label,
            "ProgramArguments": [executable, "run"],
            "KeepAlive": ["SuccessfulExit": false],
            "ThrottleInterval": 15,
            "StandardOutPath": agentLog,
            "StandardErrorPath": agentLog,
        ]
        if let config = EdgeConfigFile.load(from: EdgeConfigFile.fileURL(environment: environment)) {
            var sockets: [String: Any] = [
                EdgeSocketActivation.primaryName: Self.socketSpec(port: config.port)
            ]
            for (index, listener) in config.listeners.enumerated() {
                sockets[EdgeSocketActivation.listenerName(index: index)] = Self.socketSpec(port: listener.port)
            }
            plist["Sockets"] = sockets
            plist["RunAtLoad"] = false
        } else {
            plist["RunAtLoad"] = true
        }
        if let override = environment["RELAYDOCK_CONFIG_DIR"],
           !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            plist["EnvironmentVariables"] = ["RELAYDOCK_CONFIG_DIR": override]
        }
        return plist
    }

    /// One launchd socket spec: IPv4 loopback, stream, TCP.
    static func socketSpec(port: Int) -> [String: Any] {
        [
            "SockFamily": "IPv4",
            "SockNodeName": "127.0.0.1",
            "SockServiceName": port,
            "SockType": "stream",
            "SockProtocol": "TCP",
        ]
    }

    /// Prints the launchd agent plist (XML) for this install. The installer
    /// writes it to `~/Library/LaunchAgents/com.nxhung.relaydock.edge.plist`.
    static func runAgentPlist(environment: [String: String]) -> Never {
        guard let plist = agentPlist(environment: environment) else {
            FileHandle.standardError.write(Data(
                "relaydock-edge: could not locate this executable for the agent plist.\n".utf8
            ))
            exit(1)
        }
        do {
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            FileHandle.standardOutput.write(data)
        } catch {
            FileHandle.standardError.write(Data(
                "relaydock-edge: could not render the agent plist (\(error.localizedDescription)).\n".utf8
            ))
            exit(1)
        }
        exit(0)
    }

    /// `_NSGetExecutablePath` plus `realpath`, so the plist points at the
    /// installed binary rather than a transient build path.
    static func ownExecutablePath() -> String? {
        var size = UInt32(PATH_MAX)
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard _NSGetExecutablePath(&buffer, &size) == 0 else { return nil }
        guard let resolved = realpath(buffer, nil) else {
            return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        }
        defer { free(resolved) }
        let bytes = UnsafeBufferPointer(start: resolved, count: strlen(resolved))
            .map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    // MARK: - Install / uninstall

    /// `relaydock-edge install [--launcher <path>]`: installs the PATH wrapper
    /// for this user. The Edge binary is this process's own executable; the
    /// launcher defaults to a sibling named `relaydock-launch` — true both in
    /// `build/` and in the app bundle's Resources.
    static func runInstall(arguments: [String], environment: [String: String]) -> Never {
        var launcherPath: String?
        var index = 0
        while index < arguments.count {
            switch arguments[index] {
            case "--launcher":
                guard index + 1 < arguments.count else {
                    FileHandle.standardError.write(Data("relaydock-edge: --launcher needs a path.\n".utf8))
                    exit(2)
                }
                launcherPath = arguments[index + 1]
                index += 2
            case let unknown:
                FileHandle.standardError.write(Data(
                    "relaydock-edge: unknown argument '\(unknown)'.\n\(usageText)\n".utf8
                ))
                exit(2)
            }
        }
        guard let own = ownExecutablePath() else {
            FileHandle.standardError.write(Data("relaydock-edge: could not locate this executable.\n".utf8))
            exit(1)
        }
        let sourceEdge = URL(fileURLWithPath: own)
        let sourceLauncher = launcherPath.map { URL(fileURLWithPath: $0) }
            ?? sourceEdge.deletingLastPathComponent().appending(path: "relaydock-launch")
        guard FileManager.default.isExecutableFile(atPath: sourceLauncher.path) else {
            FileHandle.standardError.write(Data(
                "relaydock-edge: launcher binary not found at \(sourceLauncher.path); pass --launcher.\n".utf8
            ))
            exit(1)
        }
        exit(EdgeInstaller(environment: environment).install(sourceLauncher: sourceLauncher, sourceEdge: sourceEdge))
    }

    /// `relaydock-edge uninstall`: removes the PATH wrapper, the launchd
    /// agent, both installed binaries, and edge.json. User data — the proxy
    /// pool and Edge's script cache — stays.
    static func runUninstall(environment: [String: String]) -> Never {
        exit(EdgeInstaller(environment: environment).uninstall())
    }

    // MARK: - Status

    static func runStatus(environment: [String: String]) -> Never {
        let configURL = EdgeConfigFile.fileURL(environment: environment)
        guard let config = EdgeConfigFile.load(from: configURL) else {
            print("RelayDock Edge is not configured (\(configURL.path) is missing).")
            exit(1)
        }
        print("edge.json: port \(config.port)")
        guard let status = EdgeStatusClient.fetchStatus(config: config) else {
            print("RelayDock Edge is not running.")
            exit(1)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(status), let text = String(data: data, encoding: .utf8) {
            print(text)
        }
        exit(0)
    }
}
