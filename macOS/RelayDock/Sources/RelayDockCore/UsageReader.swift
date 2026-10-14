import Foundation
import SQLite3

public struct ModelUsage: Equatable, Identifiable, Sendable {
    public var model: String
    public var requests: Int
    public var id: String { model }

    public init(model: String, requests: Int) {
        self.model = model
        self.requests = requests
    }
}

public struct UsageSummary: Equatable, Sendable {
    public var days: Int
    public var assistantMessages: Int
    public var userMessages: Int
    public var sessions: Int
    public var inputTokens: Int
    public var outputTokens: Int
    public var reasoningTokens: Int
    public var cacheReadTokens: Int
    public var cacheWriteTokens: Int
    public var cost: Double
    public var models: [ModelUsage]
    public var activeAccountID: String

    public init(
        days: Int,
        assistantMessages: Int,
        userMessages: Int,
        sessions: Int,
        inputTokens: Int,
        outputTokens: Int,
        reasoningTokens: Int,
        cacheReadTokens: Int,
        cacheWriteTokens: Int,
        cost: Double,
        models: [ModelUsage],
        activeAccountID: String
    ) {
        self.days = days
        self.assistantMessages = assistantMessages
        self.userMessages = userMessages
        self.sessions = sessions
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.reasoningTokens = reasoningTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWriteTokens = cacheWriteTokens
        self.cost = cost
        self.models = models
        self.activeAccountID = activeAccountID
    }

    public var totalTokens: Int {
        inputTokens + outputTokens + reasoningTokens + cacheReadTokens + cacheWriteTokens
    }
}

public enum UsageReaderError: LocalizedError, Equatable {
    case databaseNotFound(String)
    case cannotOpen(String)
    case cannotRead(String)

    public var errorDescription: String? {
        switch self {
        case .databaseNotFound(let path): "OpenCode database not found at \(path)"
        case .cannotOpen(let detail): "Cannot open the OpenCode database: \(detail)"
        case .cannotRead(let detail): "Cannot read OpenCode usage data: \(detail)"
        }
    }
}

public struct UsageReader: Sendable {
    public let databaseURL: URL

    public init(databaseURL: URL? = nil, environment: [String: String] = ProcessInfo.processInfo.environment) {
        if let databaseURL {
            self.databaseURL = databaseURL
        } else {
            self.databaseURL = Self.defaultDatabaseURL(environment: environment)
        }
    }

    public func activeAccountID() -> String {
        guard let database = try? openDatabase() else { return "anonymous" }
        defer { sqlite3_close(database) }
        return readActiveAccountID(from: database)
    }

    public func summary(days: Int) throws -> UsageSummary {
        let normalizedDays = min(365, max(1, days))
        let database = try openDatabase()
        defer { sqlite3_close(database) }
        let since = Int64(Date().timeIntervalSince1970 * 1_000) - Int64(normalizedDays) * 86_400_000

        let aggregateSQL = """
        SELECT
          COUNT(CASE WHEN json_extract(data,'$.role') = 'assistant' THEN 1 END),
          COUNT(CASE WHEN json_extract(data,'$.role') = 'user' THEN 1 END),
          COUNT(DISTINCT session_id),
          SUM(COALESCE(json_extract(data,'$.tokens.input'), 0)),
          SUM(COALESCE(json_extract(data,'$.tokens.output'), 0)),
          SUM(COALESCE(json_extract(data,'$.tokens.reasoning'), 0)),
          SUM(COALESCE(json_extract(data,'$.tokens.cache.read'), 0)),
          SUM(COALESCE(json_extract(data,'$.tokens.cache.write'), 0)),
          SUM(COALESCE(json_extract(data,'$.cost'), 0))
        FROM message WHERE time_created >= ?
        """
        let aggregate = try prepare(aggregateSQL, database: database)
        defer { sqlite3_finalize(aggregate) }
        sqlite3_bind_int64(aggregate, 1, since)
        guard sqlite3_step(aggregate) == SQLITE_ROW else {
            throw UsageReaderError.cannotRead(databaseMessage(database))
        }

        let modelsSQL = """
        SELECT COALESCE(json_extract(data,'$.modelID'), 'unknown'), COUNT(*)
        FROM message
        WHERE json_extract(data,'$.role') = 'assistant' AND time_created >= ?
        GROUP BY 1 ORDER BY 2 DESC LIMIT 10
        """
        let modelsStatement = try prepare(modelsSQL, database: database)
        defer { sqlite3_finalize(modelsStatement) }
        sqlite3_bind_int64(modelsStatement, 1, since)
        var models: [ModelUsage] = []
        while true {
            let result = sqlite3_step(modelsStatement)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW else { throw UsageReaderError.cannotRead(databaseMessage(database)) }
            models.append(ModelUsage(
                model: columnString(modelsStatement, 0) ?? "unknown",
                requests: nonnegativeCount(sqlite3_column_int64(modelsStatement, 1))
            ))
        }

        return UsageSummary(
            days: normalizedDays,
            assistantMessages: nonnegativeCount(sqlite3_column_int64(aggregate, 0)),
            userMessages: nonnegativeCount(sqlite3_column_int64(aggregate, 1)),
            sessions: nonnegativeCount(sqlite3_column_int64(aggregate, 2)),
            inputTokens: nonnegativeCount(sqlite3_column_int64(aggregate, 3)),
            outputTokens: nonnegativeCount(sqlite3_column_int64(aggregate, 4)),
            reasoningTokens: nonnegativeCount(sqlite3_column_int64(aggregate, 5)),
            cacheReadTokens: nonnegativeCount(sqlite3_column_int64(aggregate, 6)),
            cacheWriteTokens: nonnegativeCount(sqlite3_column_int64(aggregate, 7)),
            cost: sqlite3_column_double(aggregate, 8),
            models: models,
            activeAccountID: readActiveAccountID(from: database)
        )
    }

    private func openDatabase() throws -> OpaquePointer {
        guard FileManager.default.fileExists(atPath: databaseURL.path) else {
            throw UsageReaderError.databaseNotFound(databaseURL.path)
        }
        var database: OpaquePointer?
        let result = sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil)
        guard result == SQLITE_OK, let database else {
            let detail = database.map { databaseMessage($0) } ?? "SQLite error \(result)"
            if let database { sqlite3_close(database) }
            throw UsageReaderError.cannotOpen(detail)
        }
        return database
    }

    private func prepare(_ sql: String, database: OpaquePointer) throws -> OpaquePointer {
        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard result == SQLITE_OK, let statement else {
            throw UsageReaderError.cannotRead(databaseMessage(database))
        }
        return statement
    }

    private func readActiveAccountID(from database: OpaquePointer) -> String {
        guard let statement = try? prepare("SELECT active_account_id FROM account_state WHERE id = 1", database: database) else {
            return "anonymous"
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW,
              let value = columnString(statement, 0), !value.isEmpty else { return "anonymous" }
        return value
    }

    private func databaseMessage(_ database: OpaquePointer) -> String {
        String(cString: sqlite3_errmsg(database))
    }

    private func columnString(_ statement: OpaquePointer, _ index: Int32) -> String? {
        guard let value = sqlite3_column_text(statement, index) else { return nil }
        let count = Int(sqlite3_column_bytes(statement, index))
        return String(decoding: UnsafeBufferPointer(start: value, count: count), as: UTF8.self)
    }

    private func nonnegativeCount(_ value: Int64) -> Int {
        Int(max(0, min(Int64(Int.max), value)))
    }

    private static func defaultDatabaseURL(environment: [String: String]) -> URL {
        if let xdgDataHome = environment["XDG_DATA_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines), !xdgDataHome.isEmpty {
            return URL(fileURLWithPath: xdgDataHome, isDirectory: true)
                .appending(path: "opencode/opencode.db")
        }
        let configuredHome = environment["HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let home = configuredHome.flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser
        return home.appending(path: ".local/share/opencode/opencode.db")
    }
}
