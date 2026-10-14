import Foundation
import Testing
@testable import RelayDockCore

struct QuotaWatcherTests {
    @Test func parserOnlyAcceptsQuotaRetryEventsAndCalculatesUtcReset() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let payload = Data(#"{"type":"session.status","properties":{"sessionID":"session-1","status":{"type":"retry","attempt":2,"next":3000,"action":{"reason":"free_tier_limit","provider":"opencode","title":"Limit","message":"Wait"}}}}"#.utf8)

        let event = try #require(QuotaEventParser.parse(payload, now: now))

        #expect(event.reason == "free_tier_limit")
        #expect(event.sessionID == "session-1")
        #expect(event.attempt == 2)
        #expect(event.next == 3000)
        #expect(event.resetAt != nil)
        #expect(Double(event.resetAt!) / 1_000 > now.timeIntervalSince1970)
        #expect(Double(event.resetAt!) / 1_000 - now.timeIntervalSince1970 <= 24 * 60 * 60)

        let rateLimit = Data(#"{"type":"session.status","properties":{"status":{"type":"retry","action":{"reason":"account_rate_limit"}}}}"#.utf8)
        #expect(QuotaEventParser.parse(rateLimit, now: now)?.resetAt == nil)
        #expect(QuotaEventParser.parse(Data(#"{"type":"message.updated"}"#.utf8), now: now) == nil)
        #expect(QuotaEventParser.parse(Data(#"{"type":"session.status","properties":{"status":{"type":"retry","action":{"reason":"other"}}}}"#.utf8), now: now) == nil)
    }

    @Test @MainActor func watcherReadsV2SseAndReportsSuccessfulAccountRotation() async throws {
        let requestRecorder = QuotaRequestRecorder()
        let eventRecorder = QuotaEventRecorder()
        let payload = #"{"type":"session.status","properties":{"sessionID":"stream-session","status":{"type":"retry","action":{"reason":"account_rate_limit","title":"Limit reached","message":"Try another account"}}}}"#
        let watcher = QuotaWatcher(
            connectionProvider: { OpenCodeAPIConnection(port: 12345, majorVersion: 2, headers: ["Authorization": "Basic test"]) },
            autoRotateEnabled: { true },
            rotateAccount: { _ in .attempted("Work account") },
            lineStreamProvider: { request in
                requestRecorder.set(request)
                return makeQuotaLines(payload)
            }
        )
        watcher.onEvent = { eventRecorder.append($0) }

        watcher.start()
        try await waitForEvents(eventRecorder, count: 2)
        await watcher.stop()

        #expect(requestRecorder.request?.url?.path == "/api/event")
        #expect(requestRecorder.request?.value(forHTTPHeaderField: "Accept") == "text/event-stream")
        #expect(requestRecorder.request?.value(forHTTPHeaderField: "Authorization") == "Basic test")
        #expect(eventRecorder.events.count >= 2)
        #expect(eventRecorder.events.first?.sessionID == "stream-session")
        #expect(eventRecorder.events.last?.rotatedTo == "Work account")
    }

    @Test @MainActor func watcherUsesV1EventEndpointAndDoesNotRotateWhenDisabled() async throws {
        let requestRecorder = QuotaRequestRecorder()
        let eventRecorder = QuotaEventRecorder()
        let rotationRecorder = RotationRecorder()
        let payload = #"{"type":"session.status","properties":{"status":{"type":"retry","action":{"reason":"free_tier_limit","title":"Limit","message":"Wait"}}}}"#
        let watcher = QuotaWatcher(
            connectionProvider: { OpenCodeAPIConnection(port: 12346, majorVersion: 1) },
            autoRotateEnabled: { false },
            rotateAccount: { _ in rotationRecorder.record(); return .attempted("unused") },
            lineStreamProvider: { request in
                requestRecorder.set(request)
                return makeQuotaLines(payload)
            }
        )
        watcher.onEvent = { eventRecorder.append($0) }

        watcher.start()
        try await waitForEvents(eventRecorder, count: 1)
        await watcher.stop()

        #expect(requestRecorder.request?.url?.path == "/event")
        #expect(eventRecorder.events.first?.reason == "free_tier_limit")
        #expect(rotationRecorder.count == 0)
    }

    @MainActor
    private func waitForEvents(_ recorder: QuotaEventRecorder, count: Int) async throws {
        for _ in 0..<100 {
            if recorder.events.count >= count { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for quota events")
    }
}

private func makeQuotaLines(_ payload: String) -> QuotaEventLineStream {
    AsyncThrowingStream { continuation in
        continuation.yield(": connected")
        continuation.yield("data: \(payload)")
        continuation.yield("")
        continuation.finish()
    }
}

private final class QuotaRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedRequest: URLRequest?

    var request: URLRequest? {
        lock.lock()
        defer { lock.unlock() }
        return storedRequest
    }

    func set(_ request: URLRequest) {
        lock.lock()
        defer { lock.unlock() }
        storedRequest = request
    }
}

@MainActor
private final class QuotaEventRecorder {
    var events: [QuotaEvent] = []
    func append(_ event: QuotaEvent) { events.append(event) }
}

@MainActor
private final class RotationRecorder {
    private(set) var count = 0
    func record() { count += 1 }
}
