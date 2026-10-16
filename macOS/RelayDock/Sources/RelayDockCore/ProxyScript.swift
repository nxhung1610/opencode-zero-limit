import Foundation

/// Errors surfaced when a custom JavaScript proxy script cannot produce a proxy.
public enum ProxyScriptError: LocalizedError, Equatable {
    case empty
    case tooLarge
    case failed(String)
    case timedOut
    case invalidResult(String)

    public var errorDescription: String? {
        switch self {
        case .empty:
            "The script is empty."
        case .tooLarge:
            "The script is larger than 64 KB."
        case .failed(let message):
            "The script failed: \(message)"
        case .timedOut:
            "The script timed out before it returned a proxy."
        case .invalidResult(let value):
            "The script returned \(value), which is not a proxy URL or host:port."
        }
    }
}

/// Resolves custom JavaScript proxy entries.
///
/// Scripts run in a sandboxed JavaScriptCore context with no file, process, or
/// module access (`ProxyScriptRuntime` + `ProxyScriptShim` build the
/// environment). The surface is Node-flavoured but synchronous underneath:
/// `fetch`/`await`, `setTimeout`/`setInterval`, `URL`, `Buffer`, `TextEncoder`/
/// `TextDecoder`, `crypto` (sha-256/384/512, HMAC, UUID, random bytes),
/// `structuredClone`, `performance.now`, the synchronous `http.get`/
/// `http.post` helpers, `btoa`/`atob`, and a no-op `console`. A global `cache`
/// object persists between runs of the same entry — in memory only. The script
/// must `return` a proxy URL or `host:port`; any error, timeout, or invalid
/// result fails closed.
public enum ProxyScriptRunner {
    public static let defaultTimeout: TimeInterval = 10
    private static let maximumScriptBytes = 64 * 1024

    public static func resolve(_ script: String, cacheID: String? = nil, timeout: TimeInterval = defaultTimeout) throws -> String {
        try resolve(script: script, cacheID: cacheID, timeout: timeout) { script, cacheID in
            ProxyScriptRuntime.run(script: script, cacheID: cacheID, timeout: timeout)
        }
    }

    /// Deadline wrapper around an evaluator. The seam keeps the timeout logic
    /// testable without running an endless script.
    static func resolve(
        script: String,
        cacheID: String?,
        timeout: TimeInterval,
        evaluate: @escaping @Sendable (String, String?) -> Result<String, ProxyScriptError>
    ) throws -> String {
        let trimmed = script.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ProxyScriptError.empty }
        guard trimmed.utf8.count <= maximumScriptBytes else { throw ProxyScriptError.tooLarge }

        let execution = SyncBox<Result<String, ProxyScriptError>>()
        let worker = Thread {
            execution.finish(evaluate(trimmed, cacheID))
        }
        worker.name = "RelayDock proxy script"
        worker.qualityOfService = .userInitiated
        worker.stackSize = 2 * 1024 * 1024
        worker.start()

        guard execution.wait(timeout: timeout) else {
            // JavaScriptCore cannot interrupt a running script. The worker is
            // abandoned and releases its resources when the script ends on its
            // own or when the process exits; selection still fails closed.
            throw ProxyScriptError.timedOut
        }
        switch execution.value {
        case .success(let url):
            return url
        case .failure(let error):
            throw error
        case nil:
            throw ProxyScriptError.failed("the script produced no result")
        }
    }
}

/// A synchronous hand-off between a worker thread and its caller, used instead
/// of async/await because `selectForSpawn()` is a synchronous API.
final class SyncBox<Value: Sendable>: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var stored: Value?

    func finish(_ value: Value) {
        lock.lock()
        stored = value
        lock.unlock()
        semaphore.signal()
    }

    /// Returns false when the timeout expires before a value arrives.
    func wait(timeout: TimeInterval) -> Bool {
        semaphore.wait(timeout: .now() + timeout) == .success
    }

    var value: Value? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}
