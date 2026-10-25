import RelayDockCore
import SwiftUI

enum FreeUsageProbeStatus: Equatable, Sendable {
    case checking
    case passed
    case failed
    case skipped
}

/// Shared status presentation for proxy rows — one source of truth for the
/// copy and color used by both the pool window and the menu bar panel.
enum ProxyStatus {
    /// Row status copy, aware of what the mode means for this proxy:
    /// Auto excludes failed proxies, so a failure reads as "Failed · excluded".
    static func text(
        for proxy: ProxyEntry,
        mode: ProxyMode,
        isTesting: Bool,
        probeStatus: FreeUsageProbeStatus? = nil,
        now: Date = Date()
    ) -> String {
        if !proxy.enabled { return "Disabled" }
        if let limitedUntil = proxy.freeUsageLimitedUntil,
           let remaining = remainingTime(until: limitedUntil, now: now) {
            return "Free limit · \(remaining) left"
        }
        switch probeStatus {
        case .checking: return "Checking quota…"
        case .passed: return "Quota OK"
        case .failed: return "Quota test failed"
        case .skipped: return "Quota test skipped"
        case nil: break
        }
        if isTesting { return "Testing…" }
        guard let health = proxy.health else { return "Not tested" }
        guard health.ok else { return mode == .auto ? "Failed · excluded" : "Failed" }
        if let latency = health.latencyMs { return "Passed · \(Int(latency.rounded())) ms" }
        return "Passed"
    }

    /// Ink weight for `text(for:mode:isTesting:)`: healthy rows stay quiet and
    /// a failure takes full ink, so the row reads without hue.
    static func color(
        for proxy: ProxyEntry,
        isTesting: Bool,
        probeStatus: FreeUsageProbeStatus? = nil,
        now: Date = Date()
    ) -> Color {
        guard proxy.enabled else { return AppTheme.inkMuted }
        if proxy.isFreeUsageLimited(at: now.timeIntervalSince1970) { return AppTheme.ink }
        switch probeStatus {
        case .checking: return AppTheme.inkMuted
        case .failed: return AppTheme.ink
        case .passed, .skipped, nil: break
        }
        if isTesting, probeStatus == nil { return AppTheme.inkMuted }
        guard let health = proxy.health else { return AppTheme.inkMuted }
        return health.ok ? AppTheme.inkMuted : AppTheme.ink
    }

    /// Compact remaining cooldown, rounded up so an active limit never shows
    /// zero before its deadline. The row refreshes once per second while active.
    static func remainingTime(until deadline: Double, now: Date = Date()) -> String? {
        let totalSeconds = Int(ceil(deadline - now.timeIntervalSince1970))
        guard totalSeconds > 0 else { return nil }

        let day = totalSeconds / 86_400
        let hour = (totalSeconds % 86_400) / 3_600
        let minute = (totalSeconds % 3_600) / 60
        let second = totalSeconds % 60

        if day > 0 {
            return hour > 0 ? "\(day)d \(hour)h" : "\(day)d"
        }
        if totalSeconds >= 3_600 {
            return minute > 0 ? "\(totalSeconds / 3_600)h \(minute)m" : "\(totalSeconds / 3_600)h"
        }
        if totalSeconds >= 60 {
            return second > 0 ? "\(totalSeconds / 60)m \(second)s" : "\(totalSeconds / 60)m"
        }
        return "\(second)s"
    }

    /// Health-only summary without mode context, for detail rows like "Last test".
    static func healthSummary(for proxy: ProxyEntry) -> String {
        guard let health = proxy.health else { return "Not tested" }
        guard health.ok else { return "Failed" }
        if let latency = health.latencyMs { return "Passed · \(Int(latency.rounded())) ms" }
        return "Passed"
    }

    /// Compact age of the last check ("2m ago", "1h ago"), or `nil` when
    /// there is no millisecond timestamp to read. Checks are stored in
    /// milliseconds; a legacy seconds value reads as unknown, not as a wrong
    /// date.
    static func checkedAgo(for proxy: ProxyEntry, now: Date = Date()) -> String? {
        guard let health = proxy.health,
              health.checkedAt > 1_000_000_000_000 else { return nil }
        let seconds = now.timeIntervalSince1970 - health.checkedAt / 1_000
        if seconds < 60 { return "just now" }
        if seconds < 3_600 { return "\(Int(seconds / 60))m ago" }
        if seconds < 86_400 { return "\(Int(seconds / 3_600))h ago" }
        return "\(Int(seconds / 86_400))d ago"
    }

    /// Full row detail for tooltips and VoiceOver: outcome, error, and age.
    static func detail(for proxy: ProxyEntry, now: Date = Date()) -> String {
        guard proxy.enabled else { return "Disabled" }
        if let limitedUntil = proxy.freeUsageLimitedUntil,
           let remaining = remainingTime(until: limitedUntil, now: now) {
            return "OpenCode free-usage limit · excluded for \(remaining)"
        }
        guard let health = proxy.health else { return "Not tested yet" }
        let age = checkedAgo(for: proxy, now: now).map { " · \($0)" } ?? ""
        if health.ok {
            let latency = health.latencyMs.map { " · \(Int($0.rounded())) ms" } ?? ""
            return "Passed\(latency)\(age)"
        }
        let error = health.error.map { " · \($0)" } ?? ""
        return "Failed\(error)\(age)"
    }
}
