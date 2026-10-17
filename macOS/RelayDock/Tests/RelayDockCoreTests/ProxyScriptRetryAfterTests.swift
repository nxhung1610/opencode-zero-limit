import Foundation
import Testing
@testable import RelayDockCore

struct ProxyScriptRetryAfterTests {
    @Test func parsesProviderCooldownMessages() {
        #expect(proxyScriptRetryAfterSeconds(from: "bestproxy: Con 9s moi co the doi proxy") == 9)
        #expect(proxyScriptRetryAfterSeconds(from: "bestproxy: Còn 12s mới có thể đổi proxy") == 12)
        #expect(proxyScriptRetryAfterSeconds(from: "The script exited with status 1: Con 30s moi co the doi proxy") == 30)
        #expect(proxyScriptRetryAfterSeconds(from: "con\t5s") == 5)
    }

    @Test func clampsToAtLeastOneSecond() {
        #expect(proxyScriptRetryAfterSeconds(from: "con 0s") == 1)
    }

    @Test func ignoresUnrelatedMessages() {
        #expect(proxyScriptRetryAfterSeconds(from: "connection refused") == nil)
        #expect(proxyScriptRetryAfterSeconds(from: "no digits here") == nil)
        #expect(proxyScriptRetryAfterSeconds(from: "") == nil)
        // `con` must be its own word: "reconcile" and "conditions" never match.
        #expect(proxyScriptRetryAfterSeconds(from: "reconcile 5s conditions") == nil)
    }
}
