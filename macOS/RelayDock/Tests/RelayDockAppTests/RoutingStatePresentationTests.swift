import Foundation
import RelayDockCore
import Testing
@testable import RelayDockApp

/// The consequence line is the one honesty contract the window and the menu
/// bar panel both render — it must describe the direct fallback exactly when
/// the pool opted into it, and keep the fail-closed promise otherwise.
struct RoutingStatePresentationTests {
    @Test func failClosedCopyChangesOnlyWithTheDirectFallbackSetting() {
        let autoEmpty = ProxyState(mode: .auto, proxies: [])
        #expect(RoutingStatePresentation.consequence(for: autoEmpty).text == "Enable a proxy before a consumer can use Auto mode.")

        let autoEmptyFallback = ProxyState(mode: .auto, proxies: [], directFallback: true)
        let emptyCopy = RoutingStatePresentation.consequence(for: autoEmptyFallback)
        #expect(emptyCopy.text == "No proxies are enabled. Edge connects directly until one is.")
        #expect(emptyCopy.isWarning)

        let manualGap = ProxyState(mode: .manual, manualId: nil, proxies: [])
        #expect(RoutingStatePresentation.consequence(for: manualGap).text.contains("fails closed"))
        let manualGapFallback = ProxyState(mode: .manual, manualId: nil, proxies: [], directFallback: true)
        #expect(RoutingStatePresentation.consequence(for: manualGapFallback).text.contains("connects directly"))

        let selected = ProxyEntry(id: "px_a", label: "A", url: "http://proxy.example:8080")
        let manual = ProxyState(mode: .manual, manualId: "px_a", proxies: [selected])
        #expect(RoutingStatePresentation.consequence(for: manual).text.contains("no direct fallback"))
        let manualFallback = ProxyState(mode: .manual, manualId: "px_a", proxies: [selected], directFallback: true)
        #expect(RoutingStatePresentation.consequence(for: manualFallback).text.contains("falls back to a direct connection"))

        let failed = ProxyEntry(
            id: "px_b",
            label: "B",
            url: "http://proxy.example:8080",
            health: ProxyHealth(ok: false, checkedAt: 1, error: "Timeout")
        )
        let autoFailed = ProxyState(mode: .auto, proxies: [failed])
        #expect(RoutingStatePresentation.consequence(for: autoFailed).text.contains("fail closed"))
        let autoFailedFallback = ProxyState(mode: .auto, proxies: [failed], directFallback: true)
        #expect(RoutingStatePresentation.consequence(for: autoFailedFallback).text.contains("falls back to direct connections"))
    }
}
