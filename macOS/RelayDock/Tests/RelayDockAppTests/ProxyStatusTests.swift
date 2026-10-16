import RelayDockCore
import SwiftUI
import Testing

@testable import RelayDockApp

@Suite struct ProxyStatusTests {
    private func entry(enabled: Bool = true, health: ProxyHealth? = nil) -> ProxyEntry {
        ProxyEntry(
            id: "px_test",
            label: "gateway.example:8080",
            url: "http://gateway.example:8080",
            enabled: enabled,
            health: health
        )
    }

    @Test func disabledWinsOverEverything() {
        let proxy = entry(enabled: false, health: ProxyHealth(ok: true, latencyMs: 8))
        #expect(ProxyStatus.text(for: proxy, mode: .auto, isTesting: true) == "Disabled")
    }

    @Test func testingShowsProgressCopy() {
        let proxy = entry(health: ProxyHealth(ok: true, latencyMs: 8))
        #expect(ProxyStatus.text(for: proxy, mode: .auto, isTesting: true) == "Testing…")
    }

    @Test func untestedShowsNotTested() {
        #expect(ProxyStatus.text(for: entry(), mode: .auto, isTesting: false) == "Not tested")
    }

    @Test func failedCopyDependsOnMode() {
        let proxy = entry(health: ProxyHealth(ok: false, error: "Timeout"))
        #expect(ProxyStatus.text(for: proxy, mode: .auto, isTesting: false) == "Failed · excluded")
        #expect(ProxyStatus.text(for: proxy, mode: .manual, isTesting: false) == "Failed")
        #expect(ProxyStatus.text(for: proxy, mode: .off, isTesting: false) == "Failed")
    }

    @Test func passedShowsRoundedLatency() {
        let proxy = entry(health: ProxyHealth(ok: true, latencyMs: 42.4))
        #expect(ProxyStatus.text(for: proxy, mode: .auto, isTesting: false) == "Passed · 42 ms")
        #expect(ProxyStatus.healthSummary(for: proxy) == "Passed · 42 ms")
    }

    @Test func colorTracksFailure() {
        #expect(ProxyStatus.color(for: entry(health: ProxyHealth(ok: false)), isTesting: false) == .orange)
        #expect(ProxyStatus.color(for: entry(health: ProxyHealth(ok: true)), isTesting: false) == .secondary)
        #expect(ProxyStatus.color(for: entry(enabled: false, health: ProxyHealth(ok: false)), isTesting: false) == .secondary)
    }
}
