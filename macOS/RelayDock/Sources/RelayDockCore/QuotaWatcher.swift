import Foundation

public struct QuotaEvent: Equatable, Sendable {
    public var reason: String
    public var provider: String
    public var title: String
    public var message: String
    public var link: String?
    public var sessionID: String
    public var attempt: Int
    public var next: Int
    public var resetAt: Int64?
    public var rotatedTo: String?
    public var at: Int64

    public init(
        reason: String,
        provider: String,
        title: String,
        message: String,
        link: String?,
        sessionID: String,
        attempt: Int,
        next: Int,
        resetAt: Int64?,
        rotatedTo: String? = nil,
        at: Int64
    ) {
        self.reason = reason
        self.provider = provider
        self.title = title
        self.message = message
        self.link = link
        self.sessionID = sessionID
        self.attempt = attempt
        self.next = next
        self.resetAt = resetAt
        self.rotatedTo = rotatedTo
        self.at = at
    }
}

public enum QuotaRotationResult: Sendable {
    case noCandidate
    case attempted(String?)
}

public enum QuotaEventParser {
    public static func parse(_ data: Data, now: Date = Date()) -> QuotaEvent? {
        guard let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
              let root = value as? [String: Any],
              root["type"] as? String == "session.status",
              let properties = root["properties"] as? [String: Any],
              let status = properties["status"] as? [String: Any],
              status["type"] as? String == "retry",
              let action = status["action"] as? [String: Any] else { return nil }

        let reason = action["reason"] as? String ?? ""
        guard reason == "free_tier_limit" || reason == "account_rate_limit" else { return nil }

        let resetAt: Int64?
        if reason == "free_tier_limit" {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(secondsFromGMT: 0)!
            let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))!
            resetAt = Int64(tomorrow.timeIntervalSince1970 * 1_000)
        } else {
            resetAt = nil
        }

        return QuotaEvent(
            reason: reason,
            provider: action["provider"] as? String ?? "opencode",
            title: action["title"] as? String ?? "Usage limit reached",
            message: action["message"] as? String ?? "",
            link: action["link"] as? String,
            sessionID: properties["sessionID"] as? String ?? "",
            attempt: max(0, integer(status["attempt"])),
            next: max(0, integer(status["next"])),
            resetAt: resetAt,
            at: Int64(now.timeIntervalSince1970 * 1_000)
        )
    }

    private static func integer(_ value: Any?) -> Int {
        guard let number = value as? NSNumber, number.doubleValue.isFinite else { return 0 }
        return Int(clamping: number.int64Value)
    }
}

public typealias QuotaEventLineStream = AsyncThrowingStream<String, Error>
public typealias QuotaEventLineStreamProvider = @Sendable (URLRequest) async throws -> QuotaEventLineStream
public typealias QuotaConnectionProvider = @MainActor @Sendable () -> OpenCodeAPIConnection?
public typealias QuotaAutoRotateProvider = @MainActor @Sendable (Int) async -> QuotaRotationResult
public typealias QuotaEventHandler = @MainActor @Sendable (QuotaEvent) -> Void

@MainActor
public final class QuotaWatcher {
    private static let rotateCooldown: TimeInterval = 120

    private let connectionProvider: QuotaConnectionProvider
    private let autoRotateEnabled: @Sendable () -> Bool
    private let rotateAccount: QuotaAutoRotateProvider
    private let lineStreamProvider: QuotaEventLineStreamProvider
    private var task: Task<Void, Never>?
    private var lastRotateAt: Date?
    public var onEvent: QuotaEventHandler?

    public init(
        manager: OpenCodeManager,
        settings: SettingsStore,
        consoleService: ConsoleService
    ) {
        connectionProvider = {
            guard let port = manager.getPort(), let majorVersion = manager.getCLIMajorVersion() else { return nil }
            return OpenCodeAPIConnection(port: port, majorVersion: majorVersion, headers: manager.apiHeaders())
        }
        autoRotateEnabled = { settings.load().autoRotate }
        rotateAccount = { version in
            if version == 2 {
                guard let connections = try? await consoleService.connections(), connections.count > 1 else {
                    return .noCandidate
                }
                let sorted = connections.sorted { $0.label < $1.label }
                let activeIndex = sorted.firstIndex(where: \.active)
                let next = sorted[activeIndex.map { ($0 + 1) % sorted.count } ?? 0]
                guard !next.active else { return .noCandidate }
                do {
                    let status = try await consoleService.activate(next.id)
                    guard status.healthy else { return .attempted(nil) }
                    return .attempted(next.label)
                } catch {
                    return .attempted(nil)
                }
            }

            guard version == 1,
                  let organizations = try? await consoleService.organizations(),
                  organizations.count > 1 else { return .noCandidate }
            let sorted = organizations.sorted {
                if $0.accountEmail == $1.accountEmail { return $0.orgID < $1.orgID }
                return $0.accountEmail < $1.accountEmail
            }
            let activeIndex = sorted.firstIndex(where: \.active)
            let next = sorted[activeIndex.map { ($0 + 1) % sorted.count } ?? 0]
            guard !next.active else { return .noCandidate }
            do {
                try await consoleService.switchOrganization(accountID: next.accountID, orgID: next.orgID)
                let status = await manager.restart()
                guard status.healthy else { return .attempted(nil) }
                return .attempted("\(next.orgName) · \(next.accountEmail)")
            } catch {
                return .attempted(nil)
            }
        }
        lineStreamProvider = Self.openEventStream
    }

    public init(
        connectionProvider: @escaping QuotaConnectionProvider,
        autoRotateEnabled: @escaping @Sendable () -> Bool,
        rotateAccount: @escaping QuotaAutoRotateProvider,
        lineStreamProvider: QuotaEventLineStreamProvider? = nil
    ) {
        self.connectionProvider = connectionProvider
        self.autoRotateEnabled = autoRotateEnabled
        self.rotateAccount = rotateAccount
        self.lineStreamProvider = lineStreamProvider ?? Self.openEventStream
    }

    public func start() {
        guard task == nil else { return }
        task = Task { [weak self] in await self?.runLoop() }
    }

    public func stop() async {
        guard let current = task else { return }
        current.cancel()
        await current.value
        task = nil
    }

    private func runLoop() async {
        defer { task = nil }
        while !Task.isCancelled {
            guard let connection = connectionProvider(), connection.majorVersion == 1 || connection.majorVersion == 2 else {
                try? await Task.sleep(for: .seconds(1))
                continue
            }

            do {
                var components = URLComponents()
                components.scheme = "http"
                components.host = "127.0.0.1"
                components.port = connection.port
                components.path = connection.majorVersion == 2 ? "/api/event" : "/event"
                guard let url = components.url else { throw QuotaWatcherError.invalidURL }
                var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
                request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                for (name, value) in connection.headers { request.setValue(value, forHTTPHeaderField: name) }

                let stream = try await lineStreamProvider(request)
                var dataLines: [String] = []
                for try await line in stream {
                    if Task.isCancelled { break }
                    if line.isEmpty {
                        await handleFrame(dataLines, version: connection.majorVersion)
                        dataLines.removeAll(keepingCapacity: true)
                    } else if line.hasPrefix("data:") {
                        let value = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        dataLines.append(value)
                    }
                }
                if !dataLines.isEmpty { await handleFrame(dataLines, version: connection.majorVersion) }
            } catch {
                // A failed or closed stream is transient; reconnect below without disturbing OpenCode.
            }

            if !Task.isCancelled { try? await Task.sleep(for: .seconds(2)) }
        }
    }

    private func handleFrame(_ lines: [String], version: Int) async {
        guard !lines.isEmpty,
              let data = lines.joined(separator: "\n").data(using: .utf8),
              var event = QuotaEventParser.parse(data) else { return }
        onEvent?(event)

        guard autoRotateEnabled() else { return }
        if let lastRotateAt, Date().timeIntervalSince(lastRotateAt) < Self.rotateCooldown { return }
        switch await rotateAccount(version) {
        case .noCandidate:
            break
        case .attempted(let label):
            lastRotateAt = Date()
            guard let label else { return }
            event.rotatedTo = label
            onEvent?(event)
        }
    }

    private static func openEventStream(_ request: URLRequest) async throws -> QuotaEventLineStream {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 0
        let session = URLSession(configuration: configuration)
        return AsyncThrowingStream { continuation in
            let streamTask = Task {
                do {
                    let (bytes, response) = try await session.bytes(for: request)
                    guard let response = response as? HTTPURLResponse else { throw QuotaWatcherError.nonHTTPResponse }
                    guard response.statusCode == 200 else { throw QuotaWatcherError.httpStatus(response.statusCode) }
                    for try await line in bytes.lines {
                        if Task.isCancelled { break }
                        continuation.yield(line)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in
                streamTask.cancel()
                session.invalidateAndCancel()
            }
        }
    }
}

private enum QuotaWatcherError: Error {
    case invalidURL
    case nonHTTPResponse
    case httpStatus(Int)
}
