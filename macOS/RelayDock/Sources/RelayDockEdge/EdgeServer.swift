import Darwin
import Foundation
import RelayDockCore

/// The loopback listener. The port bind is the single-instance mutex: a
/// spawn that loses the race verifies the winner and exits silently; any
/// other occupant is a loud boot error, because consumers hold this port in
/// their environment and it never renumbers.
///
/// Both paths serve the same blocking accept loop:
/// - launchd socket activation (P3): the agent plist declares `Sockets`, so
///   launchd owns the listener and starts Edge on the first connection. The
///   inherited descriptor is served as-is.
/// - a self-bound socket for spawn-on-demand and direct `run` invocations.
///   It is bound with SO_REUSEADDR so a restart can rebind while the previous
///   incarnation's connections drain through TIME_WAIT — a live listener
///   still conflicts, so the mutex holds.
///
/// A server can also pin one entry: per-account listeners (extra `edge.json`
/// ports) route every connection through exactly that pool entry.
final class EdgeServer: @unchecked Sendable {
    enum Role: Sendable {
        case primary
        case pinned(entryID: String)

        var entryID: String? {
            if case .pinned(let entryID) = self { return entryID }
            return nil
        }
    }

    private enum Mode {
        case activated(fd: Int32)
        case selfBound
    }

    private enum BindResult {
        case bound(Int32)
        /// The port is already taken (EADDRINUSE).
        case conflict
        case failed(String)
    }

    private let mode: Mode
    private let port: UInt16
    private let role: Role
    private let daemon: EdgeDaemon
    private let config: EdgeConfigFile
    private let log: EdgeLog
    private let listenerReport: EdgeListenerReport?
    private var acceptor: EdgeFDAcceptor?

    init(
        config: EdgeConfigFile,
        daemon: EdgeDaemon,
        log: EdgeLog,
        role: Role = .primary,
        port requestedPort: UInt16? = nil,
        activationName: String = EdgeSocketActivation.primaryName,
        listenerReport: EdgeListenerReport? = nil
    ) throws {
        guard let port = requestedPort ?? UInt16(exactly: config.port) else {
            throw EdgeSocketError.connectFailed("invalid port \(config.port)")
        }
        self.port = port
        self.role = role
        self.daemon = daemon
        self.config = config
        self.log = log
        self.listenerReport = listenerReport
        if let fd = EdgeSocketActivation.listeningDescriptors(named: activationName).first {
            self.mode = .activated(fd: fd)
        } else {
            self.mode = .selfBound
        }
    }

    func start() {
        switch mode {
        case .activated(let fd):
            startAccepting(fd: fd, activated: true)
        case .selfBound:
            switch Self.makeLoopbackListener(port: port) {
            case .bound(let fd):
                startAccepting(fd: fd, activated: false)
            case .conflict:
                handlePortConflict()
            case .failed(let message):
                log.error("boot: listener failed: \(message)")
                exit(1)
            }
        }
    }

    private func startAccepting(fd: Int32, activated: Bool) {
        listenerReport?.note(port: Int(port), entryID: role.entryID, activated: activated)
        if activated {
            log.info("listening on 127.0.0.1:\(port) (launchd socket activation)")
        } else {
            log.info("listening on 127.0.0.1:\(port)")
        }
        warmPrimary()
        let acceptor = EdgeFDAcceptor(fd: fd, log: log) { [weak self] clientFD, peerPort in
            guard let self else {
                Darwin.close(clientFD)
                return
            }
            EdgeClientConnection(
                socket: EdgeSocket(fd: clientFD, peerPort: peerPort, label: "relaydock.edge.client"),
                peerPort: peerPort,
                daemon: self.daemon,
                config: self.config,
                log: self.log,
                pinnedEntryID: self.role.entryID
            ).start()
        }
        self.acceptor = acceptor
        acceptor.start()
    }

    /// A blocking loopback listener with SO_REUSEADDR (see the type comment
    /// for why reuse is safe here).
    private static func makeLoopbackListener(port: UInt16) -> BindResult {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return .failed("socket() failed (POSIX \(errno))") }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else {
            let code = errno
            Darwin.close(fd)
            if code == EADDRINUSE { return .conflict }
            return .failed("bind 127.0.0.1:\(port) failed (POSIX \(code))")
        }
        guard Darwin.listen(fd, 64) == 0 else {
            let code = errno
            Darwin.close(fd)
            return .failed("listen on 127.0.0.1:\(port) failed (POSIX \(code))")
        }
        return .bound(fd)
    }

    /// The primary listener's port was taken. Give a compatible winner a
    /// moment to answer: during a cold-start race the other instance may
    /// still be binding when this check runs. Keep the window shorter than
    /// the launcher's readiness timeout so a genuinely foreign occupant
    /// still lands a loud boot error in the log. Pinned listeners must never
    /// take the whole daemon down — they warn and step aside.
    private func handlePortConflict() {
        if case .pinned(let entryID) = role {
            log.warn(
                "listener: could not bind 127.0.0.1:\(port) for \(entryID) "
                + "(the port is already in use); skipping this listener"
            )
            return
        }
        for _ in 0..<4 {
            if let status = EdgeStatusClient.fetchStatus(config: config, timeout: 0.4) {
                log.info("another RelayDock Edge (pid \(status.pid)) already serves 127.0.0.1:\(port); exiting quietly")
                exit(0)
            }
            Thread.sleep(forTimeInterval: 0.15)
        }
        log.error(
            "boot: port \(port) is held by another process that is not a compatible RelayDock Edge; "
            + "reinstall the wrapper (scripts/opencode-wrapper.sh install) or free the port"
        )
        exit(1)
    }

    /// Only the primary listener resolves on boot and runs the check
    /// scheduler; pinned listeners stay cold until their first connection.
    private func warmPrimary() {
        guard case .primary = role else { return }
        let daemon = self.daemon
        Task {
            await daemon.warmup()
            await daemon.startScheduler()
        }
    }
}

/// Blocking `accept(2)` loop over a listening descriptor — either inherited
/// from launchd socket activation or self-bound with SO_REUSEADDR. One
/// accepted descriptor becomes one client connection; the loop owns its own
/// thread so the shared executor is never blocked.
final class EdgeFDAcceptor: @unchecked Sendable {
    private let fd: Int32
    private let log: EdgeLog
    private let onAccept: @Sendable (Int32, UInt16?) -> Void

    init(fd: Int32, log: EdgeLog, onAccept: @escaping @Sendable (Int32, UInt16?) -> Void) {
        self.fd = fd
        self.log = log
        self.onAccept = onAccept
    }

    func start() {
        let fd = self.fd
        let log = self.log
        let onAccept = self.onAccept
        Thread.detachNewThread {
            while true {
                var address = sockaddr_storage()
                var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
                let client = withUnsafeMutablePointer(to: &address) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.accept(fd, $0, &length) }
                }
                if client < 0 {
                    let code = errno
                    if code == EINTR || code == ECONNABORTED { continue }
                    if code == EMFILE || code == ENFILE {
                        log.warn("accept: descriptor limit reached (POSIX \(code)); backing off")
                        Thread.sleep(forTimeInterval: 0.2)
                        continue
                    }
                    log.error("accept failed: POSIX \(code); exiting")
                    exit(1)
                }
                var on: Int32 = 1
                Darwin.setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
                onAccept(client, Self.peerPort(of: client))
            }
        }
    }

    /// The client's ephemeral port, for status attribution.
    private static func peerPort(of fd: Int32) -> UInt16? {
        var address = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let result = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.getpeername(fd, $0, &length) }
        }
        guard result == 0 else { return nil }
        return UInt16(bigEndian: address.sin_port)
    }
}
