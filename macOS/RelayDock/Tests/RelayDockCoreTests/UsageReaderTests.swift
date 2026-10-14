import Foundation
import SQLite3
import Testing
@testable import RelayDockCore

struct UsageReaderTests {
    @Test func readsOpenCodeDatabaseReadOnlyAndAggregatesUsageAndActiveAccount() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appending(path: "opencode/opencode.db")
        try FileManager.default.createDirectory(at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        var database: OpaquePointer?
        #expect(sqlite3_open(databaseURL.path, &database) == SQLITE_OK)
        guard let database else { Issue.record("SQLite database did not open"); return }
        defer { sqlite3_close(database) }

        try execute("CREATE TABLE message (time_created INTEGER, data TEXT, session_id TEXT)", database: database)
        try execute("CREATE TABLE account_state (id INTEGER PRIMARY KEY, active_account_id TEXT)", database: database)
        try execute("INSERT INTO account_state(id, active_account_id) VALUES (1, 'account-test')", database: database)
        let now = Int64(Date().timeIntervalSince1970 * 1_000)
        try execute("""
        INSERT INTO message(time_created, data, session_id) VALUES
        (\(now), '{"role":"assistant","modelID":"model-a","tokens":{"input":12,"output":7,"reasoning":2,"cache":{"read":3,"write":1}},"cost":0.25}', 'session-a'),
        (\(now), '{"role":"user"}', 'session-a'),
        (\(now - 20 * 86_400_000), '{"role":"assistant","modelID":"old-model","tokens":{"input":100}}', 'old-session')
        """, database: database)

        let reader = UsageReader(databaseURL: databaseURL)
        let summary = try reader.summary(days: 7)

        #expect(summary.days == 7)
        #expect(summary.assistantMessages == 1)
        #expect(summary.userMessages == 1)
        #expect(summary.sessions == 1)
        #expect(summary.inputTokens == 12)
        #expect(summary.outputTokens == 7)
        #expect(summary.reasoningTokens == 2)
        #expect(summary.cacheReadTokens == 3)
        #expect(summary.cacheWriteTokens == 1)
        #expect(summary.cost == 0.25)
        #expect(summary.models == [ModelUsage(model: "model-a", requests: 1)])
        #expect(summary.activeAccountID == "account-test")
        #expect(reader.activeAccountID() == "account-test")
    }

    @Test func usesOpenCodeXDGPathAndFallsBackToAnonymousAccount() throws {
        let reader = UsageReader(environment: ["XDG_DATA_HOME": "/tmp/opencode-data", "HOME": "/Users/example"])
        #expect(reader.databaseURL.path == "/tmp/opencode-data/opencode/opencode.db")
        #expect(reader.activeAccountID() == "anonymous")
        do {
            _ = try reader.summary(days: 30)
            Issue.record("A missing OpenCode database must be surfaced")
        } catch {
            #expect(error as? UsageReaderError == .databaseNotFound(reader.databaseURL.path))
        }
    }

    @Test func clampsRequestedUsageWindowToOneThrough365Days() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let databaseURL = root.appending(path: "opencode.db")
        var database: OpaquePointer?
        #expect(sqlite3_open(databaseURL.path, &database) == SQLITE_OK)
        guard let database else { Issue.record("SQLite database did not open"); return }
        defer { sqlite3_close(database) }
        try execute("CREATE TABLE message (time_created INTEGER, data TEXT, session_id TEXT)", database: database)

        let reader = UsageReader(databaseURL: databaseURL)
        #expect(try reader.summary(days: 0).days == 1)
        #expect(try reader.summary(days: 900).days == 365)
    }

    private func execute(_ sql: String, database: OpaquePointer) throws {
        var error: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(database, sql, nil, nil, &error)
        guard result == SQLITE_OK else {
            let detail = error.map { String(cString: $0) } ?? "SQLite error \(result)"
            if let error { sqlite3_free(error) }
            throw NSError(domain: "RelayDock.UsageReaderTests", code: Int(result), userInfo: [NSLocalizedDescriptionKey: detail])
        }
    }
}
