import Foundation
import Testing
@testable import RelayDockCore

struct SpawnRouteTests {
    private let entries = [
        ProxyEntry(id: "px_a", label: "A", url: "http://a.example:8080", health: ProxyHealth(ok: true)),
        ProxyEntry(id: "px_b", label: "B", url: "http://b.example:8080", health: ProxyHealth(ok: true)),
    ]

    @Test func offModeResolvesNoRoute() throws {
        #expect(try resolveSpawnRoute(state: ProxyState(mode: .off), accountID: "default", bindings: [:]) == nil)
    }

    @Test func manualModeUsesTheSelectionWithoutRebinding() throws {
        let state = ProxyState(mode: .manual, manualId: "px_b", proxies: entries)
        let route = try resolveSpawnRoute(state: state, accountID: "default", bindings: [:])
        #expect(route?.entryID == "px_b")
        #expect(route?.proxyURL == "http://b.example:8080")
        #expect(route?.isNewBinding == false)
    }

    @Test func manualModeWithoutASelectionFailsClosed() {
        #expect(throws: ProxyStoreError.self) {
            _ = try resolveSpawnRoute(state: ProxyState(mode: .manual, proxies: entries), accountID: "default", bindings: [:])
        }
    }

    @Test func autoPrefersAnUnboundEntryAndFlagsTheNewBinding() throws {
        let state = ProxyState(mode: .auto, proxies: entries)
        let route = try resolveSpawnRoute(state: state, accountID: "second", bindings: ["default": "px_a"])
        #expect(route?.entryID == "px_b")
        #expect(route?.proxyURL == "http://b.example:8080")
        #expect(route?.isNewBinding == true)
    }

    @Test func autoKeepsAnExistingBinding() throws {
        let state = ProxyState(mode: .auto, proxies: entries)
        let route = try resolveSpawnRoute(state: state, accountID: "default", bindings: ["default": "px_b"])
        #expect(route?.entryID == "px_b")
        #expect(route?.isNewBinding == false)
    }

    @Test func autoSkipsFailedHealthWhileASuccessfulSiblingExists() throws {
        let state = ProxyState(mode: .auto, proxies: [
            ProxyEntry(id: "px_dead", label: "Dead", url: "http://dead.example:8080", health: ProxyHealth(ok: false)),
            ProxyEntry(id: "px_live", label: "Live", url: "http://live.example:8080", health: ProxyHealth(ok: true)),
        ])
        let route = try resolveSpawnRoute(state: state, accountID: "default", bindings: [:])
        #expect(route?.entryID == "px_live")
    }

    @Test func autoSkipsDisabledEntries() throws {
        let state = ProxyState(mode: .auto, proxies: [
            ProxyEntry(id: "px_off", label: "Off", url: "http://off.example:8080", enabled: false),
            ProxyEntry(id: "px_on", label: "On", url: "http://on.example:8080", health: ProxyHealth(ok: true)),
        ])
        let route = try resolveSpawnRoute(state: state, accountID: "default", bindings: [:])
        #expect(route?.entryID == "px_on")
    }

    @Test func autoWithoutUsableEntriesFailsClosed() {
        #expect(throws: ProxyStoreError.self) {
            _ = try resolveSpawnRoute(state: ProxyState(mode: .auto, proxies: []), accountID: "default", bindings: [:])
        }
    }

    @Test func resolveProxyEntryURLRejectsDamagedStaticURLs() {
        #expect(throws: ProxyStoreError.self) {
            _ = try resolveProxyEntryURL(ProxyEntry(id: "px_bad", label: "Bad", url: "ftp://bad.example:21"))
        }
        let resolved = try? resolveProxyEntryURL(ProxyEntry(id: "px_ok", label: "Ok", url: "http://ok.example:8080"))
        #expect(resolved == "http://ok.example:8080")
    }
}
