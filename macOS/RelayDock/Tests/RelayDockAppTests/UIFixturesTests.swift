import AppKit
import Foundation
import RelayDockCore
import SwiftUI
import Testing

@testable import RelayDockApp

/// Offscreen UI fixtures for design review, rendered through `NSHostingView`
/// so AppKit-backed controls (`Form`, `List`, buttons, segmented pickers) draw
/// exactly like they do in the real window.
///
/// Always exercises rendering; writes PNGs only when `RELAYDOCK_FIXTURE_DIR` is set:
///
/// ```sh
/// RELAYDOCK_FIXTURE_DIR=$PWD/../../build/ui-captures/fixtures swift test --filter UIFixturesTests
/// ```
@MainActor
@Suite struct UIFixturesTests {
    @Test func renderCoreStates() throws {
        _ = NSApplication.shared

        let scenarios = try Self.scenarios()
        let outputDirectory = ProcessInfo.processInfo.environment["RELAYDOCK_FIXTURE_DIR"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
        if let outputDirectory {
            try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        }

        var renderedCount = 0
        for scenario in scenarios {
            for scheme in scenario.schemes {
                let appearanceName: NSAppearance.Name = scheme == .dark ? .darkAqua : .aqua
                let representation = try Self.snapshot(
                    scenario.content.environment(\.colorScheme, scheme),
                    size: scenario.size,
                    appearance: try #require(NSAppearance(named: appearanceName))
                )
                renderedCount += 1
                if let outputDirectory {
                    let data = try #require(
                        representation.representation(using: NSBitmapImageRep.FileType.png, properties: [:])
                    )
                    try data.write(to: outputDirectory.appending(path: "\(scenario.name)-\(scheme.fixtureSlug).png"))
                }
            }
        }

        let expectedCount = scenarios.reduce(0) { $0 + $1.schemes.count }
        #expect(renderedCount == expectedCount)
    }
}

private extension ColorScheme {
    var fixtureSlug: String { self == .dark ? "dark" : "light" }
}

private struct FixtureScenario {
    let name: String
    /// Fixed point size, or `nil` to render at the content's ideal size.
    let size: CGSize?
    let schemes: [ColorScheme]
    let content: AnyView
}

private extension UIFixturesTests {
    static func scenarios() throws -> [FixtureScenario] {
        let bothSchemes: [ColorScheme] = [.dark, .light]
        let windowSize = CGSize(width: 680, height: 460)
        return [
            FixtureScenario(
                name: "routing-auto",
                size: windowSize,
                schemes: bothSchemes,
                content: window(try makeModel(mode: .auto, proxies: mixedPool))
            ),
            FixtureScenario(
                name: "routing-manual",
                size: windowSize,
                schemes: [.dark],
                content: window(try makeModel(mode: .manual, manualId: "px_gateway_east", proxies: mixedPool))
            ),
            FixtureScenario(
                name: "routing-auto-failclosed",
                size: windowSize,
                schemes: [.dark],
                content: window(try makeModel(mode: .auto, proxies: failedPool))
            ),
            FixtureScenario(
                name: "routing-off",
                size: windowSize,
                schemes: bothSchemes,
                content: window(try makeModel(mode: .off, proxies: mixedPool))
            ),
            FixtureScenario(
                name: "pool-list",
                size: windowSize,
                schemes: bothSchemes,
                content: window(try makeModel(mode: .auto, proxies: mixedPool, tab: .pool))
            ),
            FixtureScenario(
                name: "pool-empty",
                size: windowSize,
                schemes: bothSchemes,
                content: window(try makeModel(mode: .off, proxies: [], tab: .pool))
            ),
            FixtureScenario(
                name: "pool-script-entry",
                size: windowSize,
                schemes: [.dark],
                content: window(try makeModel(mode: .auto, proxies: scriptPool, tab: .pool))
            ),
            FixtureScenario(
                name: "import-sheet-single",
                size: CGSize(width: 520, height: 440),
                schemes: bothSchemes,
                content: AnyView(
                    ProxyImportSheet(model: try makeModel(mode: .off, proxies: mixedPool))
                        .background(.background)
                )
            ),
            FixtureScenario(
                name: "import-sheet-custom",
                size: CGSize(width: 520, height: 440),
                schemes: [.dark],
                content: AnyView(
                    ProxyImportSheet(
                        model: try makeModel(mode: .off, proxies: mixedPool),
                        initialScheme: .custom,
                        initialScript: "const res = http.get(\"https://api.example.com/proxy\");\nreturn JSON.parse(res).url;"
                    )
                    .background(.background)
                )
            ),
            FixtureScenario(
                name: "import-sheet-bulk",
                size: CGSize(width: 520, height: 440),
                schemes: [.dark],
                content: AnyView(
                    ProxyImportSheet(
                        model: try makeModel(mode: .off, proxies: mixedPool),
                        initialText: "http://proxy.example:8080\nsocks4a://[2001:db8::1]:1080",
                        initialMode: .bulk
                    )
                    .background(.background)
                )
            ),
            FixtureScenario(
                name: "panel-auto",
                size: nil,
                schemes: bothSchemes,
                content: panel(try makeModel(mode: .auto, proxies: mixedPool))
            ),
            FixtureScenario(
                name: "panel-manual-warning",
                size: nil,
                schemes: [.dark],
                content: panel(try makeModel(mode: .manual, manualId: "px_local_debug", proxies: mixedPool))
            ),
            FixtureScenario(
                name: "panel-auto-failclosed",
                size: nil,
                schemes: [.dark],
                content: panel(try makeModel(mode: .auto, proxies: failedPool))
            ),
            FixtureScenario(
                name: "panel-empty",
                size: nil,
                schemes: [.dark],
                content: panel(try makeModel(mode: .off, proxies: []))
            ),
            FixtureScenario(
                name: "panel-overflow",
                size: nil,
                schemes: [.dark],
                content: panel(try makeModel(mode: .auto, proxies: overflowPool))
            ),
        ]
    }

    static func snapshot<Content: View>(
        _ content: Content,
        size: CGSize?,
        appearance: NSAppearance,
        scale: CGFloat = 2
    ) throws -> NSBitmapImageRep {
        let hosting = NSHostingView(rootView: content)
        hosting.appearance = appearance
        if let size {
            hosting.frame = CGRect(origin: .zero, size: size)
        } else {
            hosting.frame = CGRect(origin: .zero, size: hosting.fittingSize)
        }
        hosting.layoutSubtreeIfNeeded()

        let bounds = hosting.bounds
        let representation = try #require(
            NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: Int(bounds.width * scale),
                pixelsHigh: Int(bounds.height * scale),
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            ),
            "Unable to allocate bitmap for snapshot"
        )
        representation.size = bounds.size
        hosting.cacheDisplay(in: bounds, to: representation)
        return representation
    }

    static func window(_ model: ProxyAppModel) -> AnyView {
        AnyView(
            RootView(model: model)
                .background(.background)
        )
    }

    static func panel(_ model: ProxyAppModel) -> AnyView {
        AnyView(
            MenuBarPanelView(model: model)
                .background(.background)
        )
    }

    static func makeModel(
        mode: ProxyMode,
        manualId: String? = nil,
        proxies: [ProxyEntry],
        tab: ProxyAppTab = .routing
    ) throws -> ProxyAppModel {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "relaydock-ui-fixtures", directoryHint: .isDirectory)
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let store = ProxyStore(configDirectory: directory)
        try store.save(ProxyState(mode: mode, manualId: manualId, proxies: proxies))
        let model = ProxyAppModel(store: store)
        model.load()
        model.selectedTab = tab
        return model
    }

    /// One passed (42 ms), one untested, one disabled, one failed — the everyday mixed pool.
    static var mixedPool: [ProxyEntry] {
        [
            ProxyEntry(
                id: "px_gateway_east",
                label: "gateway.example",
                url: "http://gateway.example:8080",
                health: ProxyHealth(ok: true, latencyMs: 42, checkedAt: 1_760_000_000)
            ),
            ProxyEntry(
                id: "px_backup_socks",
                label: "socks.fallback.example",
                url: "socks5://socks.fallback.example:1080"
            ),
            ProxyEntry(
                id: "px_local_debug",
                label: "127.0.0.1",
                url: "http://127.0.0.1:7890",
                enabled: false,
                health: ProxyHealth(ok: true, latencyMs: 8, checkedAt: 1_760_000_000)
            ),
            ProxyEntry(
                id: "px_gateway_west",
                label: "west.example",
                url: "https://west.example:8443",
                health: ProxyHealth(ok: false, checkedAt: 1_760_000_000, error: "Connection refused")
            ),
        ]
    }

    /// A custom JavaScript entry next to a normal URL entry.
    static var scriptPool: [ProxyEntry] {
        [
            ProxyEntry(
                id: "px_script_rotating",
                label: "Rotating pool",
                url: "",
                script: "const res = http.get(\"https://api.example.com/proxy\");\nreturn JSON.parse(res).url;",
                health: ProxyHealth(ok: true, latencyMs: 128, checkedAt: 1_760_000_000)
            ),
            ProxyEntry(
                id: "px_gateway_east",
                label: "gateway.example",
                url: "http://gateway.example:8080",
                health: ProxyHealth(ok: true, latencyMs: 42, checkedAt: 1_760_000_000)
            ),
        ]
    }

    /// Every enabled proxy failed its last check — Auto must fail closed.
    static var failedPool: [ProxyEntry] {
        [
            ProxyEntry(
                id: "px_gateway_east",
                label: "gateway.example",
                url: "http://gateway.example:8080",
                health: ProxyHealth(ok: false, checkedAt: 1_760_000_000, error: "Timeout")
            ),
            ProxyEntry(
                id: "px_gateway_west",
                label: "west.example",
                url: "https://west.example:8443",
                health: ProxyHealth(ok: false, checkedAt: 1_760_000_000, error: "Connection refused")
            ),
        ]
    }

    /// More than `MenuBarPanelView.maximumVisibleProxies` — exercises the "N more…" row.
    static var overflowPool: [ProxyEntry] {
        (1...8).map { index in
            ProxyEntry(
                id: "px_pool_\(index)",
                label: "edge-\(index).example",
                url: "http://edge-\(index).example:808\(index)",
                health: index % 3 == 0
                    ? nil
                    : ProxyHealth(ok: true, latencyMs: Double(18 + index * 7), checkedAt: 1_760_000_000)
            )
        }
    }
}
