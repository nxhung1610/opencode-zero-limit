import CryptoKit
import Foundation
import JavaScriptCore

/// The host half of the sandbox: builds the JavaScriptCore environment, runs
/// one script to completion with a cooperative pump (microtasks + timers), and
/// keeps the per-entry memory cache.
enum ProxyScriptRuntime {
    private static let httpTimeout: TimeInterval = 8
    private static let maximumResponseBytes = 256 * 1024
    private static let maximumRequestBytes = 64 * 1024
    private static let maximumCacheBytes = 64 * 1024

    /// Runs one script on the calling thread. The caller owns the deadline;
    /// the pump also stops itself at `timeout` so an abandoned worker exits
    /// on its own instead of burning CPU.
    static func run(script: String, cacheID: String?, timeout: TimeInterval) -> Result<String, ProxyScriptError> {
        guard let context = JSContext() else {
            return .failure(.failed("JavaScript is unavailable on this Mac"))
        }
        context.exception = nil
        installHostAPIs(in: context)
        context.evaluateScript(ProxyScriptShim.source)
        if let exception = context.exception, !exception.isUndefined {
            return .failure(.failed(describe(exception)))
        }
        injectCache(in: context, snapshot: cacheID.flatMap { ProxyScriptCache.shared.snapshot(for: $0) })

        context.evaluateScript(
            """
            __relaydockSettled = false;
            __relaydockValue = undefined;
            __relaydockError = undefined;
            __relaydockPromise = (async function() {
            \(script)
            })();
            __relaydockPromise.then(function (value) {
                if (!__relaydockSettled) {
                    __relaydockSettled = true;
                    __relaydockValue = value;
                }
            }, function (error) {
                __relaydockFail(error);
            });
            """
        )
        if let exception = context.exception, !exception.isUndefined {
            return .failure(.failed(describe(exception)))
        }

        if case .failure(let error) = pump(context, deadline: Date().addingTimeInterval(timeout)) {
            return .failure(error)
        }
        if let errorValue = context.evaluateScript("__relaydockError"), !errorValue.isUndefined, !errorValue.isNull {
            let message = context.evaluateScript("__relaydockDescribeError(__relaydockError)")?.toString()
                ?? describe(errorValue)
            return .failure(.failed(clipped(message)))
        }

        let result = context.evaluateScript("__relaydockValue")
        guard let result, !result.isUndefined, !result.isNull, let returned = result.toString() else {
            return .failure(.invalidResult("no value"))
        }
        let trimmed = returned.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = parseProxyImportLine(trimmed) else {
            return .failure(.invalidResult(quoted(trimmed)))
        }

        if let cacheID {
            let snapshot = context.evaluateScript("__relaydockSnapshot()")
            if let snapshot, !snapshot.isUndefined, !snapshot.isNull,
               let json = snapshot.toString(),
               json.hasPrefix("{"), json.utf8.count <= maximumCacheBytes {
                ProxyScriptCache.shared.store(json, for: cacheID)
            }
        }
        return .success(url)
    }

    // MARK: - Pump

    /// Drives the run forward: drains microtasks, executes due timers, and
    /// sleeps until the next timer. Since every host call is synchronous, a
    /// script can only be waiting on microtasks or timers; if neither can make
    /// progress, the run fails closed instead of spinning to the deadline.
    private static func pump(_ context: JSContext, deadline: Date) -> Result<Void, ProxyScriptError> {
        while true {
            if Date() >= deadline { return .failure(.timedOut) }
            _ = context.evaluateScript("void 0")
            if isSettled(context) { return .success(()) }
            let now = Date().timeIntervalSince1970 * 1000
            let ran = context.evaluateScript("__relaydockRunDueTimers(\(now))")?.toInt32() ?? 0
            if ran > 0 { continue }
            if isSettled(context) { return .success(()) }
            let delay = context.evaluateScript("__relaydockNextTimerDelay(\(now))")?.toDouble() ?? -1
            if delay < 0 {
                return .failure(.failed(
                    "the script did not settle (a promise never resolved and no timers are pending)"
                ))
            }
            // Slice long sleeps so the deadline stays responsive.
            Thread.sleep(forTimeInterval: min(max(delay / 1000, 0.002), 0.25))
        }
    }

    private static func isSettled(_ context: JSContext) -> Bool {
        context.evaluateScript("__relaydockSettled")?.toBool() == true
    }

    // MARK: - Cache

    private static func injectCache(in context: JSContext, snapshot: String?) {
        if let snapshot {
            context.evaluateScript("var cache = \(snapshot);")
        } else {
            context.evaluateScript("var cache = {};")
        }
    }

    // MARK: - Host APIs

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

        let shaBlock: @convention(block) (String, String) -> JSValue = { [weak context] algorithm, data in
            guard let context else { return JSValue(undefinedIn: nil) }
            guard let hex = shaHex(algorithm: algorithm, data: data) else {
                context.exception = JSValue(newErrorFromMessage: "crypto: unsupported algorithm \(algorithm)", in: context)
                return JSValue(undefinedIn: context)
            }
            return JSValue(object: hex, in: context)
        }
        context.setObject(unsafeBitCast(shaBlock, to: AnyObject.self), forKeyedSubscript: "__relaydockSHA" as NSString)

        let hmacBlock: @convention(block) (String, String, String) -> JSValue = { [weak context] algorithm, key, data in
            guard let context else { return JSValue(undefinedIn: nil) }
            guard let hex = hmacHex(algorithm: algorithm, key: key, data: data) else {
                context.exception = JSValue(newErrorFromMessage: "crypto: unsupported algorithm \(algorithm)", in: context)
                return JSValue(undefinedIn: context)
            }
            return JSValue(object: hex, in: context)
        }
        context.setObject(unsafeBitCast(hmacBlock, to: AnyObject.self), forKeyedSubscript: "__relaydockHMAC" as NSString)

        let uuidBlock: @convention(block) () -> String = {
            UUID().uuidString.lowercased()
        }
        context.setObject(unsafeBitCast(uuidBlock, to: AnyObject.self), forKeyedSubscript: "__relaydockUUID" as NSString)

        let randomHexBlock: @convention(block) (Int) -> String = { count in
            var generator = SystemRandomNumberGenerator()
            let bytes = (0..<max(count, 0)).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
            return bytes.map { String(format: "%02x", $0) }.joined()
        }
        context.setObject(unsafeBitCast(randomHexBlock, to: AnyObject.self), forKeyedSubscript: "__relaydockRandomHex" as NSString)

        let httpGetBlock: @convention(block) (JSValue, JSValue?) -> JSValue = { [weak context] urlValue, headersValue in
            guard let context else { return JSValue(undefinedIn: nil) }
            do {
                let body = try performRequest(
                    api: "http.get", method: "GET", urlString: urlValue.toString() ?? "",
                    body: nil, headersValue: headersValue
                )
                return JSValue(object: body, in: context)
            } catch {
                let message = (error as? HostAPIError)?.message ?? error.localizedDescription
                context.exception = JSValue(newErrorFromMessage: message, in: context)
                return JSValue(undefinedIn: context)
            }
        }
        let httpPostBlock: @convention(block) (JSValue, JSValue, JSValue?) -> JSValue = { [weak context] urlValue, bodyValue, headersValue in
            guard let context else { return JSValue(undefinedIn: nil) }
            do {
                let payload = bodyValue.isUndefined || bodyValue.isNull ? "" : (bodyValue.toString() ?? "")
                let body = try performRequest(
                    api: "http.post", method: "POST", urlString: urlValue.toString() ?? "",
                    body: payload, headersValue: headersValue
                )
                return JSValue(object: body, in: context)
            } catch {
                let message = (error as? HostAPIError)?.message ?? error.localizedDescription
                context.exception = JSValue(newErrorFromMessage: message, in: context)
                return JSValue(undefinedIn: context)
            }
        }
        let httpObject = JSValue(newObjectIn: context)
        httpObject?.setObject(unsafeBitCast(httpGetBlock, to: AnyObject.self), forKeyedSubscript: "get" as NSString)
        httpObject?.setObject(unsafeBitCast(httpPostBlock, to: AnyObject.self), forKeyedSubscript: "post" as NSString)
        context.setObject(httpObject, forKeyedSubscript: "http" as NSString)
    }

    // MARK: - HTTP

    private static func performRequest(
        api: String,
        method: String,
        urlString: String,
        body: String?,
        headersValue: JSValue?
    ) throws -> String {
        var headers: [String: String] = [:]
        if let headersValue, headersValue.isObject {
            guard let dictionary = headersValue.toDictionary() as? [String: String] else {
                throw HostAPIError(message: "\(api): headers must be an object of string values")
            }
            headers = dictionary
        }
        guard let url = URL(string: urlString),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host != nil else {
            throw HostAPIError(message: "\(api): only http and https URLs are supported")
        }
        if let body, body.utf8.count > maximumRequestBytes {
            throw HostAPIError(message: "\(api): the request body is larger than 64 KB")
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = httpTimeout
        configuration.timeoutIntervalForResource = httpTimeout
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: configuration)
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body.map { Data($0.utf8) }
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }

        let responseBox = SyncBox<Result<String, HostAPIError>>()
        let task = session.dataTask(with: request) { data, response, error in
            if let error {
                responseBox.finish(.failure(HostAPIError(message: "\(api): \(error.localizedDescription)")))
                return
            }
            guard let httpResponse = response as? HTTPURLResponse else {
                responseBox.finish(.failure(HostAPIError(message: "\(api): no HTTP response")))
                return
            }
            guard (200..<300).contains(httpResponse.statusCode) else {
                responseBox.finish(.failure(HostAPIError(message: "\(api): HTTP \(httpResponse.statusCode)")))
                return
            }
            let payload = data ?? Data()
            guard payload.count <= maximumResponseBytes else {
                responseBox.finish(.failure(HostAPIError(message: "\(api): the response is larger than 256 KB")))
                return
            }
            guard let text = String(data: payload, encoding: .utf8) else {
                responseBox.finish(.failure(HostAPIError(message: "\(api): the response is not UTF-8 text")))
                return
            }
            responseBox.finish(.success(text))
        }
        task.resume()

        guard responseBox.wait(timeout: httpTimeout + 1) else {
            task.cancel()
            session.invalidateAndCancel()
            throw HostAPIError(message: "\(api): the request did not finish in time")
        }
        session.finishTasksAndInvalidate()
        switch responseBox.value {
        case .success(let text):
            return text
        case .failure(let error):
            throw error
        case nil:
            throw HostAPIError(message: "\(api): no response")
        }
    }

    // MARK: - Crypto (CryptoKit)

    private static func shaHex(algorithm: String, data: String) -> String? {
        let payload = Data(data.utf8)
        switch algorithm {
        case "sha256":
            return SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        case "sha384":
            return SHA384.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        case "sha512":
            return SHA512.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        default:
            return nil
        }
    }

    private static func hmacHex(algorithm: String, key: String, data: String) -> String? {
        let payload = Data(data.utf8)
        let secret = SymmetricKey(data: Data(key.utf8))
        switch algorithm {
        case "sha256":
            return HMAC<SHA256>.authenticationCode(for: payload, using: secret).map { String(format: "%02x", $0) }.joined()
        case "sha384":
            return HMAC<SHA384>.authenticationCode(for: payload, using: secret).map { String(format: "%02x", $0) }.joined()
        case "sha512":
            return HMAC<SHA512>.authenticationCode(for: payload, using: secret).map { String(format: "%02x", $0) }.joined()
        default:
            return nil
        }
    }

    // MARK: - Messages

    private static func describe(_ exception: JSValue) -> String {
        let message = (exception.toString() ?? "unknown error")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return clipped(message)
    }

    private static func clipped(_ message: String) -> String {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count > 220 ? String(trimmed.prefix(220)) + "…" : trimmed
    }

    private static func quoted(_ value: String) -> String {
        let flattened = value
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        let clipped = flattened.count > 60 ? String(flattened.prefix(60)) + "…" : flattened
        return "\"\(clipped)\""
    }
}

/// In-memory snapshots of each entry's `cache` object, shared by every script
/// run in this process. Keyed per entry so scripts never see each other's
/// data; dropped whenever a run fails or times out.
final class ProxyScriptCache: @unchecked Sendable {
    static let shared = ProxyScriptCache()

    private let lock = NSLock()
    private var snapshots: [String: String] = [:]

    func snapshot(for id: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return snapshots[id]
    }

    func store(_ json: String, for id: String) {
        lock.lock()
        defer { lock.unlock() }
        snapshots[id] = json
    }

    /// Drops the snapshot for an entry — used when its script changes or the
    /// entry is removed, so stale data is never served to the new definition.
    func remove(for id: String) {
        lock.lock()
        defer { lock.unlock() }
        snapshots[id] = nil
    }
}

/// A failure raised by a host API inside a script; surfaced as a JavaScript
/// exception so scripts can catch it with try/catch.
private struct HostAPIError: Error {
    let message: String
}
