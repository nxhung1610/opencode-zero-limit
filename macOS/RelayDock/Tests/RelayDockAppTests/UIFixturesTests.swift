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
    /// A status shaped like a busy install: one live tunnel, a quiet recent
    /// history, and the counters the Edge panel renders.
    static func edgeLiveStatus(now: Double = Date().timeIntervalSince1970) -> EdgeStatusResponse {
        EdgeStatusResponse(
            pid: 39_179,
            port: 57_211,
            mode: .auto,
            upstream: .init(
                entryID: "px_gateway_east",
                label: "Gateway East",
                maskedURL: "http://gateway.example:8080",
                source: "static",
                resolvedAt: now - 240,
                expiresAt: now + 540
            ),
            lastErrors: [],
            counters: .init(
                resolutions: 23,
                switches: 0,
                dialFailures: 2,
                streamFailures: 1,
                directFallbacks: 2,
                tunnelsTotal: 35,
                tunnelsActive: 1
            ),
            tunnels: [
                .init(
                    clientPort: 51_001,
                    peerPid: 39_179,
                    peerName: "opencode",
                    label: "Gateway East",
                    startedAt: now - 120,
                    bytesUp: 18_000,
                    bytesDown: 4_200_000,
                    active: true
                ),
                .init(
                    clientPort: 51_002,
                    peerPid: 39_179,
                    peerName: "opencode",
                    label: "Gateway East",
                    startedAt: now - 600,
                    endedAt: now - 480,
                    bytesUp: 21_000,
                    bytesDown: 6_100_000,
                    active: false
                ),
                .init(
                    clientPort: 51_003,
                    peerPid: 40_222,
                    peerName: "opencode",
                    label: "Gateway East",
                    startedAt: now - 1_500,
                    endedAt: now - 1_400,
                    bytesUp: 9_000,
                    bytesDown: 1_800_000,
                    active: false
                ),
            ],
            launchedAt: now - 3_600
        )
    }

    static func edgeLiveModel() throws -> ProxyAppModel {
        let model = try makeModel(mode: .auto, proxies: mixedPool)
        model.applyEdgePanelForFixtures(.running(edgeLiveStatus()))
        return model
    }

    /// The panel at its fullest: live Edge accounting on top of a pool whose
    /// checks carry real millisecond timestamps, so freshness ages render too.
    static func edgeLivePanelModel() throws -> ProxyAppModel {
        let model = try makeModel(mode: .auto, proxies: recentPool)
        model.applyEdgePanelForFixtures(.running(edgeLiveStatus()))
        return model
    }

    /// Edge nowhere in sight — the panel must stay calm and say so.
    static func edgeNotRunningModel() throws -> ProxyAppModel {
        let model = try makeModel(mode: .auto, proxies: recentPool)
        model.applyEdgePanelForFixtures(.notRunning)
        return model
    }

    /// Edge running quietly: a live upstream with time left and all-zero
    /// failures — the compact card's resting shape (no Failures row).
    static func edgeQuietStatus(now: Double = Date().timeIntervalSince1970) -> EdgeStatusResponse {
        EdgeStatusResponse(
            pid: 62_361,
            port: 57_211,
            mode: .auto,
            upstream: .init(
                entryID: "px_rotating_exit",
                label: "Rotating exit",
                maskedURL: "http://rotator.example:10629",
                source: "script",
                resolvedAt: now - 60,
                expiresAt: now + 240
            ),
            lastErrors: [],
            counters: .init(
                resolutions: 12,
                switches: 0,
                dialFailures: 0,
                streamFailures: 0,
                tunnelsTotal: 6,
                tunnelsActive: 1
            ),
            tunnels: [
                .init(
                    clientPort: 52_841,
                    peerPid: 6_494,
                    peerName: "opencode",
                    label: "Rotating exit",
                    startedAt: now - 90,
                    bytesUp: 12_000,
                    bytesDown: 2_400_000,
                    active: true
                ),
                .init(
                    clientPort: 52_772,
                    peerPid: 6_494,
                    peerName: "opencode",
                    label: "Rotating exit",
                    startedAt: now - 300,
                    endedAt: now - 240,
                    bytesUp: 8_000,
                    bytesDown: 1_100_000,
                    active: false
                ),
            ],
            launchedAt: now - 7_200
        )
    }

    static func edgeQuietModel() throws -> ProxyAppModel {
        let model = try makeModel(mode: .auto, proxies: mixedPool)
        model.applyEdgePanelForFixtures(.running(edgeQuietStatus()))
        return model
    }

    /// Wrapper absent: the card's install invitation over an Edge panel that
    /// correctly reads "not installed".
    static func routingSetupNotInstalledModel() throws -> ProxyAppModel {
        let model = try makeModel(
            mode: .auto,
            proxies: mixedPool,
            routingSetupState: .notInstalled,
            routingSetupPathCheck: .unchecked
        )
        model.applyEdgePanelForFixtures(.notConfigured)
        return model
    }

    /// Wrapper present but drifted, with a login shell that resolves
    /// `opencode` to Homebrew — the card's attention shape.
    static func routingSetupAttentionModel() throws -> ProxyAppModel {
        let model = try makeModel(
            mode: .auto,
            proxies: mixedPool,
            routingSetupState: .installed(.init(agentPlistInstalled: true, componentsOutOfDate: true)),
            routingSetupPathCheck: .shadowed("/opt/homebrew/bin/opencode")
        )
        model.applyEdgePanelForFixtures(.running(edgeQuietStatus()))
        return model
    }

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
                name: "routing-auto-edge-live",
                size: windowSize,
                schemes: bothSchemes,
                content: window(try edgeLiveModel())
            ),
            FixtureScenario(
                name: "routing-auto-edge-live-tall",
                size: CGSize(width: 680, height: 640),
                schemes: bothSchemes,
                content: window(try edgeLiveModel())
            ),
            FixtureScenario(
                name: "routing-auto-edge-quiet",
                size: windowSize,
                schemes: [.dark],
                content: window(try edgeQuietModel())
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
                name: "routing-auto-fallback",
                size: windowSize,
                schemes: bothSchemes,
                content: window(try makeModel(mode: .auto, proxies: failedPool, directFallback: true))
            ),
            FixtureScenario(
                name: "routing-off",
                size: windowSize,
                schemes: bothSchemes,
                content: window(try makeModel(mode: .off, proxies: mixedPool))
            ),
            FixtureScenario(
                name: "routing-setup-not-installed",
                size: CGSize(width: 680, height: 640),
                schemes: bothSchemes,
                content: window(try routingSetupNotInstalledModel())
            ),
            FixtureScenario(
                name: "routing-setup-attention",
                size: CGSize(width: 680, height: 640),
                schemes: [.dark],
                content: window(try routingSetupAttentionModel())
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
                size: CGSize(width: 520, height: 520),
                schemes: bothSchemes,
                content: AnyView(
                    ProxyImportSheet(model: try makeModel(mode: .off, proxies: mixedPool))
                        .background(.background)
                )
            ),
            FixtureScenario(
                name: "import-sheet-custom",
                size: CGSize(width: 520, height: 520),
                schemes: [.dark],
                content: AnyView(
                    ProxyImportSheet(
                        model: try makeModel(mode: .off, proxies: mixedPool),
                        prefill: .init(
                            scheme: .custom,
                            script: "const res = http.get(\"https://api.example.com/proxy\");\nreturn JSON.parse(res).url;"
                        )
                    )
                    .background(.background)
                )
            ),
            FixtureScenario(
                name: "import-sheet-custom-empty",
                size: CGSize(width: 520, height: 520),
                schemes: [.dark],
                content: AnyView(
                    ProxyImportSheet(
                        model: try makeModel(mode: .off, proxies: mixedPool),
                        prefill: .init(scheme: .custom)
                    )
                    .background(.background)
                )
            ),
            FixtureScenario(
                name: "import-sheet-single-preview",
                size: CGSize(width: 520, height: 520),
                schemes: [.dark],
                content: AnyView(
                    ProxyImportSheet(
                        model: try makeModel(mode: .off, proxies: mixedPool),
                        prefill: .init(host: "proxy.example", port: "8080", username: "demo", password: "hunter2")
                    )
                    .background(.background)
                )
            ),
            FixtureScenario(
                name: "import-sheet-bulk",
                size: CGSize(width: 520, height: 520),
                schemes: [.dark],
                content: AnyView(
                    ProxyImportSheet(
                        model: try makeModel(mode: .off, proxies: mixedPool),
                        prefill: .init(text: "http://proxy.example:8080\nsocks4a://[2001:db8::1]:1080", mode: .bulk)
                    )
                    .background(.background)
                )
            ),
            FixtureScenario(
                name: "import-sheet-edit-script",
                size: CGSize(width: 520, height: 520),
                schemes: [.dark],
                content: AnyView(
                    ProxyImportSheet(
                        model: try makeModel(mode: .off, proxies: scriptPool),
                        editing: scriptPool[0]
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
                name: "panel-auto-fallback",
                size: nil,
                schemes: [.dark],
                content: panel(try makeModel(mode: .auto, proxies: failedPool, directFallback: true))
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
            FixtureScenario(
                name: "panel-auto-edge-live",
                size: nil,
                schemes: bothSchemes,
                content: panel(try edgeLivePanelModel())
            ),
            FixtureScenario(
                name: "panel-edge-notrunning",
                size: nil,
                schemes: [.dark],
                content: panel(try edgeNotRunningModel())
            ),
            FixtureScenario(
                name: "panel-auto-recent",
                size: nil,
                schemes: bothSchemes,
                content: panel(try makeModel(mode: .auto, proxies: recentPool))
            ),
            FixtureScenario(
                name: "panel-manual-valid",
                size: nil,
                schemes: [.dark],
                content: panel(try makeModel(mode: .manual, manualId: "px_gateway_east", proxies: mixedPool))
            ),
            FixtureScenario(
                name: "panel-update-available",
                size: nil,
                schemes: bothSchemes,
                content: panel(try updatePanelModel(.available(fixtureRelease)))
            ),
            FixtureScenario(
                name: "panel-update-ready",
                size: nil,
                schemes: [.dark],
                content: panel(try updatePanelModel(.ready(fixtureRelease)))
            ),
            FixtureScenario(
                name: "panel-update-failed",
                size: nil,
                schemes: [.dark],
                content: panel(try updatePanelModel(
                    .failed("The downloaded archive failed its SHA-256 check; nothing was installed.")
                ))
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

    /// A panel whose updater sits in a given phase, using the fixture seam so
    /// rendering never touches the network or the disk. The running build is
    /// the released v0.2.0 so the offered release reads truthfully.
    static func updatePanelModel(_ phase: UpdateModel.Phase) throws -> ProxyAppModel {
        let model = try makeModel(mode: .auto, proxies: mixedPool, currentVersion: SemanticVersion(tag: "0.2.0"))
        model.updates.applyPhaseForFixtures(phase)
        return model
    }

    static var fixtureRelease: UpdateRelease {
        UpdateRelease(
            version: SemanticVersion(tag: "0.3.0")!,
            tagName: "v0.3.0",
            zipURL: URL(string: "https://github.com/nxhung1610/relaydock/releases/download/v0.3.0/RelayDock.app.zip")!,
            checksumsURL: URL(string: "https://github.com/nxhung1610/relaydock/releases/download/v0.3.0/SHA256SUMS")!,
            releasePageURL: URL(string: "https://github.com/nxhung1610/relaydock/releases/tag/v0.3.0")!
        )
    }

    static func makeModel(
        mode: ProxyMode,
        manualId: String? = nil,
        proxies: [ProxyEntry],
        tab: ProxyAppTab = .routing,
        directFallback: Bool = false,
        currentVersion: SemanticVersion? = SemanticVersion(tag: "0.3.0"),
        routingSetupState: RoutingSetupModel.State = .installed(
            .init(agentPlistInstalled: true, componentsOutOfDate: false)
        ),
        routingSetupPathCheck: RoutingSetupModel.PathCheck = .ok
    ) throws -> ProxyAppModel {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "relaydock-ui-fixtures", directoryHint: .isDirectory)
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let store = ProxyStore(configDirectory: directory)
        try store.save(ProxyState(mode: mode, manualId: manualId, proxies: proxies, directFallback: directFallback))
        // A bundle-built version, injected: offscreen renders otherwise show
        // the test runner's missing version as "dev".
        let updates = UpdateModel(configDirectory: directory, currentVersion: currentVersion)
        // The setup card is seeded through its fixture seam: offscreen renders
        // must never read the real home directory or spawn a process.
        let routingSetup = RoutingSetupModel(
            storeDirectory: directory,
            bundledResources: nil,
            environment: [:],
            runProcess: { _, _, _ in RoutingSetupModel.ProcessResult(status: 0, stdout: "", stderr: "") }
        )
        routingSetup.applyForFixtures(state: routingSetupState, pathCheck: routingSetupPathCheck)
        let model = ProxyAppModel(store: store, updates: updates, routingSetup: routingSetup)
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

    /// The everyday mixed pool, but with millisecond check timestamps close to
    /// now — the shape real checks are stored in, so the panel's "2m ago"
    /// freshness suffix is exercised.
    static var recentPool: [ProxyEntry] {
        let now = Date().timeIntervalSince1970 * 1_000
        return [
            ProxyEntry(
                id: "px_gateway_east",
                label: "gateway.example",
                url: "http://gateway.example:8080",
                health: ProxyHealth(ok: true, latencyMs: 42, checkedAt: now - 120_000)
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
                health: ProxyHealth(ok: true, latencyMs: 8, checkedAt: now - 60_000)
            ),
            ProxyEntry(
                id: "px_gateway_west",
                label: "west.example",
                url: "https://west.example:8443",
                health: ProxyHealth(ok: false, checkedAt: now - 5_400_000, error: "Connection refused")
            ),
        ]
    }
}
