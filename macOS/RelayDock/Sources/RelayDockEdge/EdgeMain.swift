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
        case "--help", "-h", "help":
            print(usageText)
            exit(0)
        default:
            FileHandle.standardError.write(Data("relaydock-edge: unknown command '\(command)'\n\(usageText)\n".utf8))
            exit(2)
        }
    }

    static let usageText = """
    Usage: relaydock-edge [run|init|stop|status]

      run     Run the daemon (default); reads edge.json next to proxies.json.
      init    Write edge.json with a free port and a fresh token (installer).
      stop    Ask a running Edge instance to shut down.
      status  Print the live status JSON (exit 1 when not running).
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

        let daemon = EdgeDaemon(config: config, directory: directory, log: log)
        let server: EdgeServer
        do {
            server = try EdgeServer(config: config, daemon: daemon, log: log)
        } catch {
            log.error("boot: \(error.localizedDescription)")
            exit(1)
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

        server.start()

        // `dispatchMain()` never returns; without this, the release optimizer
        // may release `server` (and the signal sources) at their last use,
        // leaving a bound port whose handlers are silent no-ops.
        withExtendedLifetime((server, signalSources)) {
            dispatchMain()
        }
    }

    // MARK: - Init

    static func runInit(environment: [String: String]) -> Never {
        let configURL = EdgeConfigFile.fileURL(environment: environment)
        if let existing = EdgeConfigFile.load(from: configURL) {
            print("edge.json already configured (port \(existing.port)); keeping it.")
            exit(0)
        }
        guard let port = EdgePortProbe.firstFreePort(startingAt: EdgeConfigFile.defaultPort, attempts: 20) else {
            FileHandle.standardError.write(Data(
                "relaydock-edge: no free loopback port found near \(EdgeConfigFile.defaultPort).\n".utf8
            ))
            exit(1)
        }
        let config = EdgeConfigFile(port: port, token: EdgeConfigFile.makeRandomToken())
        do {
            try config.save(to: configURL)
        } catch {
            FileHandle.standardError.write(Data(
                "relaydock-edge: could not write \(configURL.path): \(error.localizedDescription)\n".utf8
            ))
            exit(1)
        }
        print("Wrote \(configURL.path) — port \(port)")
        exit(0)
    }

    // MARK: - Stop

    static func runStop(environment: [String: String]) -> Never {
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

    // MARK: - Status

    static func runStatus(environment: [String: String]) -> Never {
        let configURL = EdgeConfigFile.fileURL(environment: environment)
        guard let config = EdgeConfigFile.load(from: configURL) else {
            print("RelayDock Edge is not configured (\(configURL.path) is missing).")
            exit(1)
        }
        print("edge.json: port \(config.port), token \(config.token.prefix(6))…")
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
