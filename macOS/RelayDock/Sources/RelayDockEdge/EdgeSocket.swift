@preconcurrency import Network
import Foundation

enum EdgeSocketError: LocalizedError, Sendable {
    case connectFailed(String)
    case handshakeFailed(String)
    case timedOut
    case unsupported(String)
    case closed

    var errorDescription: String? {
        switch self {
        case .connectFailed(let message): "Could not connect: \(message)"
        case .handshakeFailed(let message): message
        case .timedOut: "The connection timed out."
        case .unsupported(let message): message
        case .closed: "The connection closed before the exchange completed."
        }
    }
}

/// A single-resolution async latch: the first result wins; later resolutions
/// are ignored, and a waiter arriving after resolution returns it immediately.
final class EdgeLatch<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var storedResult: Result<T, EdgeSocketError>?
    private var continuation: CheckedContinuation<T, Error>?

    func resolve(_ result: Result<T, EdgeSocketError>) {
        lock.lock()
        if let continuation {
            self.continuation = nil
            lock.unlock()
            continuation.resume(with: result.mapError { $0 as Error })
            return
        }
        if storedResult == nil { storedResult = result }
        lock.unlock()
    }

    func wait() async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let storedResult {
                lock.unlock()
                continuation.resume(with: storedResult.mapError { $0 as Error })
                return
            }
            self.continuation = continuation
            lock.unlock()
        }
    }
}

/// Runs `operation` with a deadline; on expiry the socket is cancelled so the
/// operation unblocks and the task group can drain.
func withEdgeTimeout<T: Sendable>(
    _ seconds: TimeInterval,
    cancelling socket: EdgeSocket?,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(max(seconds, 0.1) * 1_000_000_000))
            socket?.cancel()
            throw EdgeSocketError.timedOut
        }
        defer { group.cancelAll() }
        guard let result = try await group.next() else { throw EdgeSocketError.closed }
        return result
    }
}

/// A thin async wrapper around one `NWConnection`. Each instance is created,
/// used, and cancelled within a single logical connection task; the
/// `@unchecked Sendable` conformance states what that lifecycle already
/// guarantees.
final class EdgeSocket: @unchecked Sendable {
    /// Either a Network.framework connection (dialed, or accepted by our own
    /// NWListener) or a connected POSIX descriptor (inherited from launchd
    /// socket activation, or accepted by `EdgeFDAcceptor`).
    private enum Backend {
        case network(NWConnection, DispatchQueue)
        case descriptor(RawDescriptor)
    }

    private let backend: Backend
    private let lock = NSLock()
    private var started = false

    init(connection: NWConnection, label: String = "relaydock.edge.socket") {
        self.backend = .network(connection, DispatchQueue(label: label))
    }

    /// Wraps a connected descriptor. The descriptor is owned by this socket
    /// (cancelling shuts it down; deinit closes it exactly once).
    init(fd: Int32, peerPort: UInt16? = nil, label: String = "relaydock.edge.socket") {
        _ = label
        self.backend = .descriptor(RawDescriptor(fd: fd, peerPort: peerPort))
    }

    convenience init(host: String, port: UInt16, tls: Bool = false, serverName: String? = nil) {
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.noDelay = true
        let endpointPort = NWEndpoint.Port(rawValue: port) ?? NWEndpoint.Port(integerLiteral: 1)
        let parameters: NWParameters
        if tls {
            let tlsOptions = NWProtocolTLS.Options()
            if let serverName {
                sec_protocol_options_set_tls_server_name(tlsOptions.securityProtocolOptions, serverName)
            }
            parameters = NWParameters(tls: tlsOptions, tcp: tcpOptions)
        } else {
            parameters = NWParameters(tls: nil, tcp: tcpOptions)
        }
        self.init(
            connection: NWConnection(host: NWEndpoint.Host(host), port: endpointPort, using: parameters),
            label: "relaydock.edge.dial"
        )
    }

    /// The peer's port for accepted connections — a client's ephemeral port,
    /// used for status attribution.
    var remotePort: UInt16? {
        switch backend {
        case .network(let connection, _):
            if case .hostPort(_, let port) = connection.endpoint { return port.rawValue }
            return nil
        case .descriptor(let raw):
            return raw.peerPort
        }
    }

    /// True while a pooled socket is still connected and has not failed —
    /// the warm-hop pool checks this before handing it out. Descriptor-backed
    /// sockets are connected by definition.
    var isReadyForReuse: Bool {
        switch backend {
        case .descriptor: return true
        case .network(let connection, _): return connection.state == .ready
        }
    }

    func startIfNeeded() {
        guard case .network(let connection, let queue) = backend else { return }
        lock.lock()
        if started {
            lock.unlock()
            return
        }
        started = true
        lock.unlock()
        connection.start(queue: queue)
    }

    func cancel() {
        switch backend {
        case .network(let connection, _): connection.cancel()
        case .descriptor(let raw): raw.shutdown()
        }
    }

    /// Closes only the write direction: the peer observes EOF while this
    /// socket can still receive. The relay uses it to forward a client's
    /// clean half-close through the tunnel instead of tearing the tunnel down
    /// and losing the response that is still in flight.
    func halfCloseWrite() {
        switch backend {
        case .network(let connection, _):
            startIfNeeded()
            connection.send(
                content: nil,
                // Only a final context makes Network.framework emit a TCP
                // FIN; `.defaultMessage` marks a message, not a write-close.
                contentContext: .finalMessage,
                isComplete: true,
                completion: .contentProcessed { _ in }
            )
        case .descriptor(let raw):
            raw.shutdownWrite()
        }
    }

    static func describe(_ error: Error) -> String {
        guard let nwError = error as? NWError else { return error.localizedDescription }
        switch nwError {
        case .posix(let code): return "POSIX \(code.rawValue)"
        case .dns(let code): return "DNS \(code)"
        case .tls(let code): return "TLS \(code)"
        @unknown default: return "\(nwError)"
        }
    }

    func awaitReady(timeout: TimeInterval = 8) async throws {
        let connection: NWConnection
        switch backend {
        case .descriptor:
            // An inherited or accepted descriptor is connected by definition.
            return
        case .network(let nw, _):
            // A socket that already reached `.ready` (for example a pooled
            // pre-dialed hop) never fires another state update.
            if nw.state == .ready { return }
            connection = nw
        }
        let latch = EdgeLatch<Void>()
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready: latch.resolve(.success(()))
            case .failed(let error): latch.resolve(.failure(EdgeSocketError.connectFailed(Self.describe(error))))
            case .cancelled: latch.resolve(.failure(EdgeSocketError.connectFailed("cancelled")))
            // A dial target that is not accepting right now: fail fast; the
            // retry-on-dial policy makes the decision, not a hang.
            case .waiting(let error): latch.resolve(.failure(EdgeSocketError.connectFailed(Self.describe(error))))
            default: break
            }
        }
        startIfNeeded()
        try await withEdgeTimeout(timeout, cancelling: self) {
            try await latch.wait()
        }
    }

    // MARK: - Receive / send

    private func receiveRange(minimum: Int, maximum: Int) async throws -> (data: Data, isComplete: Bool) {
        switch backend {
        case .network(let connection, _):
            startIfNeeded()
            return try await withCheckedThrowingContinuation { continuation in
                connection.receive(minimumIncompleteLength: minimum, maximumLength: maximum) { data, _, isComplete, error in
                    if let error {
                        continuation.resume(throwing: EdgeSocketError.connectFailed(Self.describe(error)))
                        return
                    }
                    continuation.resume(returning: (data ?? Data(), isComplete))
                }
            }
        case .descriptor(let raw):
            // Blocking `recv` off the caller's thread. The descriptor backend
            // returns whatever has arrived; the callers already loop on
            // `isComplete`, so `minimum` only informs their framing.
            return try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    var buffer = [UInt8](repeating: 0, count: max(maximum, 1))
                    while true {
                        let count = Darwin.recv(raw.fd, &buffer, buffer.count, 0)
                        if count > 0 {
                            continuation.resume(returning: (Data(buffer.prefix(count)), false))
                            return
                        }
                        if count == 0 {
                            continuation.resume(returning: (Data(), true))
                            return
                        }
                        if errno == EINTR { continue }
                        continuation.resume(throwing: EdgeSocketError.connectFailed("POSIX \(errno)"))
                        return
                    }
                }
            }
        }
    }

    func receiveSome(maximum: Int = 65_536) async throws -> (data: Data, isComplete: Bool) {
        try await receiveRange(minimum: 1, maximum: maximum)
    }

    func receiveExactly(_ count: Int) async throws -> Data {
        var buffer = Data()
        while buffer.count < count {
            let remaining = count - buffer.count
            let (data, isComplete) = try await receiveRange(minimum: remaining, maximum: remaining)
            buffer.append(data)
            if isComplete && buffer.count < count { throw EdgeSocketError.closed }
        }
        return buffer
    }

    /// Reads through the terminating blank line and hands back whatever bytes
    /// followed it — for CONNECT, those are already tunnel payload.
    func receiveUntilHead(maximum: Int = 64 * 1024) async throws -> (head: Data, rest: Data, complete: Bool) {
        startIfNeeded()
        var buffer = Data()
        while true {
            if let range = buffer.range(of: Data("\r\n\r\n".utf8)) ?? buffer.range(of: Data("\n\n".utf8)) {
                return (
                    buffer.subdata(in: buffer.startIndex..<range.upperBound),
                    buffer.subdata(in: range.upperBound..<buffer.endIndex),
                    false
                )
            }
            if buffer.count > maximum {
                throw EdgeSocketError.handshakeFailed("The request head is larger than 64 KB.")
            }
            let (data, isComplete) = try await receiveRange(minimum: 1, maximum: maximum)
            buffer.append(data)
            if isComplete {
                return (buffer, Data(), true)
            }
        }
    }

    func send(_ data: Data) async throws {
        switch backend {
        case .network(let connection, _):
            startIfNeeded()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                connection.send(content: data, completion: .contentProcessed { error in
                    if let error {
                        continuation.resume(throwing: EdgeSocketError.connectFailed(Self.describe(error)))
                    } else {
                        continuation.resume()
                    }
                })
            }
        case .descriptor(let raw):
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    guard !data.isEmpty else {
                        continuation.resume()
                        return
                    }
                    let failure: Int32? = data.withUnsafeBytes { rawBuffer in
                        guard let base = rawBuffer.baseAddress else { return nil }
                        var offset = 0
                        while offset < rawBuffer.count {
                            let sent = Darwin.send(raw.fd, base + offset, rawBuffer.count - offset, 0)
                            if sent > 0 {
                                offset += sent
                                continue
                            }
                            if sent < 0, errno == EINTR { continue }
                            return errno
                        }
                        return nil
                    }
                    if let failure {
                        continuation.resume(throwing: EdgeSocketError.connectFailed("POSIX \(failure)"))
                    } else {
                        continuation.resume()
                    }
                }
            }
        }
    }
}

/// Owns a connected POSIX descriptor. `shutdown` wakes blocked reads and
/// writes without closing the descriptor; the close happens exactly once, in
/// deinit. Operations capture this object, so it cannot deinit — and therefore
/// cannot close — while a read or write is still in flight.
final class RawDescriptor: @unchecked Sendable {
    let fd: Int32
    let peerPort: UInt16?
    private let lock = NSLock()
    private var shutDown = false
    private var writeShutDown = false

    init(fd: Int32, peerPort: UInt16?) {
        self.fd = fd
        self.peerPort = peerPort
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    func shutdown() {
        lock.lock()
        let first = !shutDown
        shutDown = true
        lock.unlock()
        guard first else { return }
        if Darwin.shutdown(fd, SHUT_RDWR) == 0 { return }
        // macOS returns ENOTCONN from SHUT_RDWR once the peer has already
        // half-closed, and then sends no FIN of its own — the peer would wait
        // forever for EOF. SHUT_WR still delivers it.
        if errno == ENOTCONN {
            _ = Darwin.shutdown(fd, SHUT_WR)
        }
    }

    /// `SHUT_WR` only: the peer gets a FIN, blocked reads here still work.
    func shutdownWrite() {
        lock.lock()
        let first = !writeShutDown && !shutDown
        writeShutDown = true
        lock.unlock()
        if first { Darwin.shutdown(fd, SHUT_WR) }
    }

    deinit { Darwin.close(fd) }
}
