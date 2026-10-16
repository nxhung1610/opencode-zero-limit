import Foundation
import JavaScriptCore

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
/// Scripts run in a bare JavaScriptCore context with no file, process, or
/// system access. The only host APIs are `http.get(url, headers?)` — a
/// synchronous HTTP/HTTPS GET that returns the response body as a string —
/// plus `btoa`, `atob`, and a no-op `console`. The script must `return` a
/// proxy URL or `host:port`; the value is validated with the same parser as
/// imported URLs. Any error, timeout, or invalid result fails closed.
public enum ProxyScriptRunner {
    public static let defaultTimeout: TimeInterval = 10
    private static let maximumScriptBytes = 64 * 1024
    private static let httpTimeout: TimeInterval = 8
    private static let maximumResponseBytes = 256 * 1024

    public static func resolve(_ script: String, timeout: TimeInterval = defaultTimeout) throws -> String {
        try resolve(script: script, timeout: timeout) { evaluate($0) }
    }

    /// Deadline wrapper around an evaluator. The seam keeps the timeout logic
    /// testable without running an endless script.
    static func resolve(
        script: String,
        timeout: TimeInterval,
        evaluate: @escaping @Sendable (String) -> Result<String, ProxyScriptError>
    ) throws -> String {
        let trimmed = script.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ProxyScriptError.empty }
        guard trimmed.utf8.count <= maximumScriptBytes else { throw ProxyScriptError.tooLarge }

        let execution = SyncBox<Result<String, ProxyScriptError>>()
        let worker = Thread {
            execution.finish(evaluate(trimmed))
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

    // MARK: - JavaScriptCore evaluation

    private static func evaluate(_ script: String) -> Result<String, ProxyScriptError> {
        guard let context = JSContext() else {
            return .failure(.failed("JavaScript is unavailable on this Mac"))
        }
        context.exception = nil
        installHostAPIs(in: context)
        let value = context.evaluateScript("(function() {\n\(script)\n})()")
        if let exception = context.exception, !exception.isUndefined {
            return .failure(.failed(describe(exception)))
        }
        guard let value, !value.isUndefined, !value.isNull, let returned = value.toString() else {
            return .failure(.invalidResult("no value"))
        }
        let trimmed = returned.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = parseProxyImportLine(trimmed) else {
            return .failure(.invalidResult(quoted(trimmed)))
        }
        return .success(url)
    }

    private static func installHostAPIs(in context: JSContext) {
        context.evaluateScript("var console = { log: function () {}, warn: function () {}, error: function () {} };")

        let btoaBlock: @convention(block) (String) -> String = { value in
            Data(value.utf8).base64EncodedString()
        }
        context.setObject(unsafeBitCast(btoaBlock, to: AnyObject.self), forKeyedSubscript: "btoa" as NSString)

        let atobBlock: @convention(block) (String) -> JSValue = { [weak context] value in
            guard let context else { return JSValue(undefinedIn: nil) }
            guard let data = Data(base64Encoded: value, options: [.ignoreUnknownCharacters]),
                  let decoded = String(data: data, encoding: .utf8) else {
                return JSValue(nullIn: context)
            }
            return JSValue(object: decoded, in: context)
        }
        context.setObject(unsafeBitCast(atobBlock, to: AnyObject.self), forKeyedSubscript: "atob" as NSString)

        let httpGetBlock: @convention(block) (JSValue, JSValue?) -> JSValue = { [weak context] urlValue, headersValue in
            guard let context else { return JSValue(undefinedIn: nil) }
            do {
                let body = try httpGet(url: urlValue.toString() ?? "", headersValue: headersValue)
                return JSValue(object: body, in: context)
            } catch {
                let message = (error as? HostAPIError)?.message ?? error.localizedDescription
                context.exception = JSValue(newErrorFromMessage: message, in: context)
                return JSValue(undefinedIn: context)
            }
        }
        let httpObject = JSValue(newObjectIn: context)
        httpObject?.setObject(unsafeBitCast(httpGetBlock, to: AnyObject.self), forKeyedSubscript: "get" as NSString)
        context.setObject(httpObject, forKeyedSubscript: "http" as NSString)
    }

    private static func httpGet(url urlString: String, headersValue: JSValue?) throws -> String {
        var headers: [String: String] = [:]
        if let headersValue, headersValue.isObject {
            guard let dictionary = headersValue.toDictionary() as? [String: String] else {
                throw HostAPIError(message: "http.get: headers must be an object of string values")
            }
            headers = dictionary
        }
        guard let url = URL(string: urlString),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host != nil else {
            throw HostAPIError(message: "http.get: only http and https URLs are supported")
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = httpTimeout
        configuration.timeoutIntervalForResource = httpTimeout
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: configuration)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }

        let responseBox = SyncBox<Result<String, HostAPIError>>()
        let task = session.dataTask(with: request) { data, response, error in
            if let error {
                responseBox.finish(.failure(HostAPIError(message: "http.get: \(error.localizedDescription)")))
                return
            }
            guard let httpResponse = response as? HTTPURLResponse else {
                responseBox.finish(.failure(HostAPIError(message: "http.get: no HTTP response")))
                return
            }
            guard (200..<300).contains(httpResponse.statusCode) else {
                responseBox.finish(.failure(HostAPIError(message: "http.get: HTTP \(httpResponse.statusCode)")))
                return
            }
            let payload = data ?? Data()
            guard payload.count <= maximumResponseBytes else {
                responseBox.finish(.failure(HostAPIError(message: "http.get: the response is larger than 256 KB")))
                return
            }
            guard let body = String(data: payload, encoding: .utf8) else {
                responseBox.finish(.failure(HostAPIError(message: "http.get: the response is not UTF-8 text")))
                return
            }
            responseBox.finish(.success(body))
        }
        task.resume()

        guard responseBox.wait(timeout: httpTimeout + 1) else {
            task.cancel()
            session.invalidateAndCancel()
            throw HostAPIError(message: "http.get: the request did not finish in time")
        }
        session.finishTasksAndInvalidate()
        switch responseBox.value {
        case .success(let body):
            return body
        case .failure(let error):
            throw error
        case nil:
            throw HostAPIError(message: "http.get: no response")
        }
    }

    // MARK: - Messages

    private static func describe(_ exception: JSValue) -> String {
        let message = (exception.toString() ?? "unknown error")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return message.count > 220 ? String(message.prefix(220)) + "…" : message
    }

    private static func quoted(_ value: String) -> String {
        let flattened = value
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        let clipped = flattened.count > 60 ? String(flattened.prefix(60)) + "…" : flattened
        return "\"\(clipped)\""
    }
}

/// A failure raised by a host API inside a script; surfaced as a JavaScript
/// exception so scripts can catch it with try/catch.
private struct HostAPIError: Error {
    let message: String
}

/// A synchronous hand-off between a worker thread and its caller, used instead
/// of async/await because `selectForSpawn()` is a synchronous API.
private final class SyncBox<Value: Sendable>: @unchecked Sendable {
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
