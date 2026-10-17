@preconcurrency import Network
import Foundation
import RelayDockCore

/// The loopback listener. The port bind is the single-instance mutex: a
/// spawn that loses the race verifies the winner and exits silently; any
/// other occupant is a loud boot error, because consumers hold this port in
/// their environment and it never renumbers.
final class EdgeServer: @unchecked Sendable {
    private let listener: NWListener
    private let daemon: EdgeDaemon
    private let config: EdgeConfigFile
    private let log: EdgeLog
    private let queue = DispatchQueue(label: "relaydock.edge.listener")

    init(config: EdgeConfigFile, daemon: EdgeDaemon, log: EdgeLog) throws {
        guard let port = NWEndpoint.Port(rawValue: UInt16(config.port)) else {
            throw EdgeSocketError.connectFailed("invalid port \(config.port)")
        }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: port)
        parameters.allowLocalEndpointReuse = false
        self.listener = try NWListener(using: parameters)
        self.daemon = daemon
        self.config = config
        self.log = log
    }

    func start() {
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.log.info("listening on 127.0.0.1:\(self.config.port)")
                let daemon = self.daemon
                Task {
                    await daemon.warmup()
                    await daemon.startScheduler()
                }
            case .failed(let error):
                self.handleListenerFailure(error)
            case .cancelled:
                self.log.info("listener cancelled")
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else {
                connection.cancel()
                return
            }
            EdgeClientConnection(
                connection: connection,
                daemon: self.daemon,
                config: self.config,
                log: self.log
            ).start()
        }
        listener.start(queue: queue)
    }

    private func handleListenerFailure(_ error: NWError) {
        if case .posix(let code) = error, code == .EADDRINUSE {
            // The port bind is the single-instance mutex. Give the winner a
            // moment to answer: during a cold-start race the other instance
            // may still be binding when this check runs. Keep the window
            // shorter than the launcher's readiness timeout so a genuinely
            // foreign occupant still lands a loud boot error in the log.
            for _ in 0..<4 {
                if let status = EdgeStatusClient.fetchStatus(config: config, timeout: 0.4) {
                    log.info("another RelayDock Edge (pid \(status.pid)) already serves 127.0.0.1:\(config.port); exiting quietly")
                    exit(0)
                }
                Thread.sleep(forTimeInterval: 0.15)
            }
            log.error(
                "boot: port \(config.port) is held by another process that is not a compatible RelayDock Edge; "
                + "reinstall the wrapper (scripts/opencode-wrapper.sh install) or free the port"
            )
            exit(1)
        }
        log.error("boot: listener failed: \(EdgeSocket.describe(error))")
        exit(1)
    }
}
