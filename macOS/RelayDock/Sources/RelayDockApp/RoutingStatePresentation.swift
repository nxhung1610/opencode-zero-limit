import RelayDockCore
import SwiftUI

/// One source of truth for how a routing state reads. The Routing tab and
/// the menu bar panel share the same symbol, tint, headline, and consequence
/// line so the two surfaces never drift apart.
enum RoutingStatePresentation {
    /// The consequence sentence plus whether it reads as a warning.
    struct Consequence: Equatable {
        let text: String
        let isWarning: Bool
    }

    static func symbol(for state: ProxyState) -> String {
        switch state.mode {
        case .off: return "arrow.right.circle"
        case .manual: return "hand.point.up.left"
        case .auto: return "wand.and.stars"
        }
    }

    static func tint(for state: ProxyState) -> Color {
        switch state.mode {
        case .off:
            return .secondary
        case .manual:
            return validManual(in: state) != nil ? .accentColor : .orange
        case .auto:
            return state.autoEligibleProxies.isEmpty ? .orange : .green
        }
    }

    static func headline(for state: ProxyState) -> String {
        switch state.mode {
        case .off:
            return "Direct — no proxy"
        case .manual:
            guard let proxy = validManual(in: state) else { return "Manual" }
            return "Manual · \(proxy.label)"
        case .auto:
            return "Auto · \(state.autoEligibleProxies.count) eligible · \(state.enabledProxies.count) enabled"
        }
    }

    static func consequence(for state: ProxyState) -> Consequence {
        switch state.mode {
        case .off:
            return Consequence(
                text: "Off saves an explicit direct-routing policy. This app does not apply it to OpenCode.",
                isWarning: false
            )
        case .manual:
            guard validManual(in: state) != nil else {
                return Consequence(
                    text: state.directFallback
                        ? "Manual selection missing or invalid. Until it is fixed, Edge connects directly."
                        : "Manual selection missing or invalid. Routing fails closed; no direct fallback.",
                    isWarning: true
                )
            }
            return Consequence(
                text: state.directFallback
                    ? "If this proxy fails, Edge falls back to a direct connection."
                    : "If this proxy fails, routing fails closed — no direct fallback.",
                isWarning: false
            )
        case .auto:
            if state.enabledProxies.isEmpty {
                return Consequence(
                    text: state.directFallback
                        ? "No proxies are enabled. Edge connects directly until one is."
                        : "Enable a proxy before a consumer can use Auto mode.",
                    isWarning: true
                )
            } else if state.validEnabledProxies.isEmpty {
                return Consequence(
                    text: state.directFallback
                        ? "No enabled proxy has a valid URL. Edge connects directly until one does."
                        : "No enabled proxy has a valid supported URL.",
                    isWarning: true
                )
            } else if state.autoEligibleProxies.isEmpty {
                return Consequence(
                    text: state.directFallback
                        ? "All enabled proxies have a failed last check. Edge falls back to direct connections."
                        : "All enabled proxies have a failed last check. Auto will fail closed.",
                    isWarning: true
                )
            }
            return Consequence(text: "Unchecked proxies may be eligible.", isWarning: false)
        }
    }

    /// The manual selection only when it still points at an enabled, valid proxy.
    static func validManual(in state: ProxyState) -> ProxyEntry? {
        guard let id = state.manualId else { return nil }
        return state.validEnabledProxies.first(where: { $0.id == id })
    }
}
