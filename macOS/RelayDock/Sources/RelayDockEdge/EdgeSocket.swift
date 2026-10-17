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
    private let connection: NWConnection
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var started = false

    init(connection: NWConnection, label: String = "relaydock.edge.socket") {
        self.connection = connection
        self.queue = DispatchQueue(label: label)
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
        if case .hostPort(_, let port) = connection.endpoint { return port.rawValue }
        return nil
    }

    func startIfNeeded() {
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
        connection.cancel()
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
    }
}
