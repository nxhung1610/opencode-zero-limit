import Foundation
import Testing
@testable import RelayDockCore

@Suite struct EdgeCheckResponseTests {
    @Test func decodesTheWireShapeEdgeSends() throws {
        let json = #"""
        {"results":{"px_a":{"ok":true,"latencyMs":42.5,"checkedAt":1777000000000,"deferred":false},"px_b":{"ok":false,"error":"curl exit 7","checkedAt":1777000000001,"deferred":false}}}
        """#
        let response = try JSONDecoder().decode(EdgeCheckResponse.self, from: Data(json.utf8))

        #expect(response.results.count == 2)
        #expect(response.results["px_a"]?.ok == true)
        #expect(response.results["px_a"]?.latencyMs == 42.5)
        #expect(response.results["px_b"]?.ok == false)
        #expect(response.results["px_b"]?.error == "curl exit 7")
    }

    @Test func decodesDeferredResults() throws {
        let json = #"{"results":{"px_a":{"ok":false,"checkedAt":1,"error":"provider cooldown","deferred":true,"retryAfter":120}}}"#
        let response = try JSONDecoder().decode(EdgeCheckResponse.self, from: Data(json.utf8))

        let result = try #require(response.results["px_a"])
        #expect(result.deferred)
        #expect(result.retryAfter == 120)
        #expect(result.error == "provider cooldown")
    }

    @Test func toleratesMissingOptionalFields() throws {
        let json = #"{"results":{"px_a":{"ok":false,"checkedAt":1}}}"#
        let response = try JSONDecoder().decode(EdgeCheckResponse.self, from: Data(json.utf8))

        let result = try #require(response.results["px_a"])
        #expect(!result.deferred)
        #expect(result.retryAfter == nil)
        #expect(result.latencyMs == nil)
        #expect(result.error == nil)
    }

    @Test func roundTripsThroughEncoding() throws {
        let original = EdgeCheckResponse(results: [
            "px_a": .init(ok: true, latencyMs: 12, checkedAt: 99),
            "px_b": .init(ok: false, checkedAt: 100, error: "offline"),
        ])
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(EdgeCheckResponse.self, from: data)
        #expect(decoded == original)
    }
}
