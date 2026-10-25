import RelayDockCore
import SwiftUI
import Testing

@testable import RelayDockApp

@Suite struct ProxyStatusTests {
    private func entry(
        enabled: Bool = true,
        health: ProxyHealth? = nil,
        limitedUntil: Double? = nil
    ) -> ProxyEntry {
        ProxyEntry(
            id: "px_test",
            label: "gateway.example:8080",
            url: "http://gateway.example:8080",
            enabled: enabled,
            health: health,
            freeUsageLimitedUntil: limitedUntil
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

    @Test func quotaProbeStatusOverridesTheGlobalTestingCopy() {
        let proxy = entry(health: ProxyHealth(ok: true, latencyMs: 8))
        #expect(ProxyStatus.text(
            for: proxy, mode: .auto, isTesting: true, probeStatus: .checking
        ) == "Checking quota…")
        #expect(ProxyStatus.text(
            for: proxy, mode: .auto, isTesting: true, probeStatus: .passed
        ) == "Quota OK")
        #expect(ProxyStatus.text(
            for: proxy, mode: .auto, isTesting: true, probeStatus: .failed
        ) == "Quota test failed")
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

    @Test func freeUsageLimitOverridesHealthAndShowsTheRemainingTime() {
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let until = now.timeIntervalSince1970 + 3_600
        let proxy = entry(health: ProxyHealth(ok: true), limitedUntil: until)

        #expect(ProxyStatus.text(for: proxy, mode: .auto, isTesting: false, now: now) == "Free limit · 1h left")
        #expect(ProxyStatus.detail(for: proxy, now: now) == "OpenCode free-usage limit · excluded for 1h")
        #expect(ProxyStatus.color(for: proxy, isTesting: false, now: now) == AppTheme.ink)
        #expect(ProxyStatus.text(for: entry(limitedUntil: now.timeIntervalSince1970 - 1), mode: .auto, isTesting: false, now: now) == "Not tested")
    }

    @Test func remainingTimeCountsDownCompactlyAndRoundsUp() {
        let now = Date(timeIntervalSince1970: 1_760_000_000)

        #expect(ProxyStatus.remainingTime(until: now.timeIntervalSince1970 + 65, now: now) == "1m 5s")
        #expect(ProxyStatus.remainingTime(until: now.timeIntervalSince1970 + 3_599, now: now) == "59m 59s")
        #expect(ProxyStatus.remainingTime(until: now.timeIntervalSince1970 + 3_661, now: now) == "1h 1m")
        #expect(ProxyStatus.remainingTime(until: now.timeIntervalSince1970 + 86_400, now: now) == "1d")
        #expect(ProxyStatus.remainingTime(until: now.timeIntervalSince1970 + 0.2, now: now) == "1s")
        #expect(ProxyStatus.remainingTime(until: now.timeIntervalSince1970, now: now) == nil)
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
