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

    /// Color for `text(for:mode:isTesting:)`.
    static func color(for proxy: ProxyEntry, isTesting: Bool) -> Color {
        guard proxy.enabled, !isTesting, let health = proxy.health else { return .secondary }
        return health.ok ? .secondary : .orange
    }

    /// Health-only summary without mode context, for detail rows like "Last test".
    static func healthSummary(for proxy: ProxyEntry) -> String {
        guard let health = proxy.health else { return "Not tested" }
        guard health.ok else { return "Failed" }
        if let latency = health.latencyMs { return "Passed · \(Int(latency.rounded())) ms" }
        return "Passed"
    }
}
