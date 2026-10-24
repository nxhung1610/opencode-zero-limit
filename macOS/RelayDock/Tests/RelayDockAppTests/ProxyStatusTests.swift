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

    @Test func inkWeightTracksFailure() {
        #expect(ProxyStatus.color(for: entry(health: ProxyHealth(ok: false)), isTesting: false) == AppTheme.ink)
        #expect(ProxyStatus.color(for: entry(health: ProxyHealth(ok: true)), isTesting: false) == AppTheme.inkMuted)
        #expect(ProxyStatus.color(for: entry(enabled: false, health: ProxyHealth(ok: false)), isTesting: false) == AppTheme.inkMuted)
    }

    @Test func checkedAgoReadsMillisecondTimestamps() {
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let recent = entry(health: ProxyHealth(ok: true, latencyMs: 8, checkedAt: 1_759_999_880_000))
        #expect(ProxyStatus.checkedAgo(for: recent, now: now) == "2m ago")
    }

    @Test func checkedAgoHidesLegacySecondsTimestamps() {
        let legacy = entry(health: ProxyHealth(ok: true, latencyMs: 8, checkedAt: 1_760_000_000))
        #expect(ProxyStatus.checkedAgo(for: legacy, now: Date()) == nil)
    }

    @Test func checkedAgoCoversFreshHoursAndDays() {
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let fresh = entry(health: ProxyHealth(ok: true, checkedAt: 1_759_999_990_000))
        #expect(ProxyStatus.checkedAgo(for: fresh, now: now) == "just now")
        let hourly = entry(health: ProxyHealth(ok: true, checkedAt: 1_759_995_400_000))
        #expect(ProxyStatus.checkedAgo(for: hourly, now: now) == "1h ago")
        let daily = entry(health: ProxyHealth(ok: true, checkedAt: 1_759_827_200_000))
        #expect(ProxyStatus.checkedAgo(for: daily, now: now) == "2d ago")
    }

    @Test func detailCarriesErrorAndAge() {
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let failed = entry(health: ProxyHealth(ok: false, checkedAt: 1_759_999_880_000, error: "Connection refused"))
        #expect(ProxyStatus.detail(for: failed, now: now) == "Failed · Connection refused · 2m ago")
    }

    @Test func detailWithoutHealthOrWhileDisabled() {
        #expect(ProxyStatus.detail(for: entry()) == "Not tested yet")
        #expect(ProxyStatus.detail(for: entry(enabled: false)) == "Disabled")
    }
}
