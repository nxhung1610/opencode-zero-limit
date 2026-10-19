import Foundation
import Testing
@testable import RelayDockCore

struct ProxyScriptCacheTransferTests {
    @Test func exportIncludesStoredSnapshots() throws {
        let cacheID = "transfer-export-\(UUID().uuidString)"
        _ = try ProxyScriptRunner.resolve(
            "cache.url = \"http://127.0.0.1:9001\"; return cache.url;",
            cacheID: cacheID
        )
        let exported = exportProxyScriptCacheSnapshots()
        let snapshot = try #require(exported[cacheID])
        let parsed = try JSONSerialization.jsonObject(with: Data(snapshot.utf8)) as? [String: Any]
        let object = try #require(parsed)
        #expect(object["url"] as? String == "http://127.0.0.1:9001")
    }

    @Test func importFeedsTheNextRunWithoutCallingTheProviderAgain() throws {
        let source = "transfer-source-\(UUID().uuidString)"
        _ = try ProxyScriptRunner.resolve(
            "cache.url = \"http://127.0.0.1:9002\"; return cache.url;",
            cacheID: source
        )
        let snapshot = try #require(exportProxyScriptCacheSnapshots()[source])

        let target = "transfer-target-\(UUID().uuidString)"
        importProxyScriptCacheSnapshots([target: snapshot])
        let url = try ProxyScriptRunner.resolve(
            "if (cache.url) { return cache.url; } throw new Error(\"provider should not run\");",
            cacheID: target
        )
        #expect(url == "http://127.0.0.1:9002")
    }

    @Test func importSkipsMalformedAndOversizedSnapshots() throws {
        let malformed = "transfer-malformed-\(UUID().uuidString)"
        let oversized = "transfer-oversized-\(UUID().uuidString)"
        let huge = "{\"url\":\"" + String(repeating: "x", count: 70 * 1024) + "\"}"
        importProxyScriptCacheSnapshots([malformed: "not json{", oversized: huge])

        // Both ids must start from an empty cache; the oversized snapshot
        // would exceed the 64 KB cap if it had been accepted.
        for id in [malformed, oversized] {
            let url = try ProxyScriptRunner.resolve(
                "return cache.url ? cache.url : \"http://127.0.0.1:9100\";",
                cacheID: id
            )
            #expect(url == "http://127.0.0.1:9100")
        }
    }

    @Test func importMergesInsteadOfReplacing() throws {
        let first = "transfer-merge-a-\(UUID().uuidString)"
        let second = "transfer-merge-b-\(UUID().uuidString)"
        importProxyScriptCacheSnapshots([first: "{\"url\":\"http://127.0.0.1:9101\"}"])
        importProxyScriptCacheSnapshots([second: "{\"url\":\"http://127.0.0.1:9102\"}"])
        let exported = exportProxyScriptCacheSnapshots()
        #expect(exported[first] != nil)
        #expect(exported[second] != nil)
    }

    @Test func cachedURLReadsTheResolutionFieldFromTheSnapshot() {
        let id = "cached-url-\(UUID().uuidString)"
        importProxyScriptCacheSnapshots([id: #"{"url":"http://127.0.0.1:9104","expiresAt":9999999999999}"#])
        #expect(proxyScriptCachedURL(for: id) == "http://127.0.0.1:9104")
    }

    @Test func cachedURLIsNilWithoutAUsableURLField() {
        let missing = "cached-missing-\(UUID().uuidString)"
        let blank = "cached-blank-\(UUID().uuidString)"
        let wrongType = "cached-type-\(UUID().uuidString)"
        importProxyScriptCacheSnapshots([
            blank: #"{"url":"   "}"#,
            wrongType: #"{"url": 42}"#,
        ])
        #expect(proxyScriptCachedURL(for: missing) == nil)
        #expect(proxyScriptCachedURL(for: blank) == nil)
        #expect(proxyScriptCachedURL(for: wrongType) == nil)
    }
}
