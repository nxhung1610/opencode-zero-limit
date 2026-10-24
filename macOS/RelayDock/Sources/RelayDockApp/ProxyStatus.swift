import RelayDockCore
import SwiftUI

/// Shared status presentation for proxy rows — one source of truth for the
/// copy and color used by both the pool window and the menu bar panel.
enum ProxyStatus {
    /// Row status copy, aware of what the mode means for this proxy:
    /// Auto excludes failed proxies, so a failure reads as "Failed · excluded".
    static func text(for proxy: ProxyEntry, mode: ProxyMode, isTesting: Bool) -> String {
        if !proxy.enabled { return "Disabled" }
        if isTesting { return "Testing…" }
        guard let health = proxy.health else { return "Not tested" }
        guard health.ok else { return mode == .auto ? "Failed · excluded" : "Failed" }
        if let latency = health.latencyMs { return "Passed · \(Int(latency.rounded())) ms" }
        return "Passed"
    }

    /// Ink weight for `text(for:mode:isTesting:)`: healthy rows stay quiet and
    /// a failure takes full ink, so the row reads without hue.
    static func color(for proxy: ProxyEntry, isTesting: Bool) -> Color {
        guard proxy.enabled, !isTesting, let health = proxy.health else { return AppTheme.inkMuted }
        return health.ok ? AppTheme.inkMuted : AppTheme.ink
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
