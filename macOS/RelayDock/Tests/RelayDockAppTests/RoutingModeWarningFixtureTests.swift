import AppKit
import Foundation
import RelayDockCore
import SwiftUI
import Testing
@testable import RelayDockApp

@MainActor
struct RoutingModeWarningFixtureTests {
    @Test func rendersWarningAndPersistentNoticeInBothAppearances() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ProxyStore(configDirectory: directory)
        _ = try store.importProxies("http://proxy.example:8080")
        let report = OpenCodeRoutingSnapshot(servers: [.init(pid: 28_455, startedAt: 1, route: .missingProxy)])
        let model = ProxyAppModel(store: store, routingProbe: { _ in report })
        model.load()
        await model.selectMode(.auto)
        let request = try #require(model.pendingRoutingChange)
        model.confirmRoutingChange(request)
        let output = ProcessInfo.processInfo.environment["RELAYDOCK_FIXTURE_DIR"].map { URL(fileURLWithPath: $0) }
        if let output { try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true) }

        for (scheme, appearance, slug) in [
            (ColorScheme.light, NSAppearance.Name.aqua, "light"),
            (ColorScheme.dark, NSAppearance.Name.darkAqua, "dark"),
        ] {
            let views: [(String, AnyView)] = [
                ("mode-change-warning", AnyView(RoutingModeWarningView(request: request, cancel: {}, confirm: {}))),
                ("mode-change-warning-help", AnyView(RoutingModeWarningView(request: request, showsRecovery: true, cancel: {}, confirm: {}))),
                ("mode-change-notice", AnyView(OpenCodeRoutingNotice(model: model).padding(20).frame(width: 500))),
                ("mode-change-menu", AnyView(MenuBarPanelView(model: model))),
            ]
            for (name, view) in views {
                let host = NSHostingView(rootView: view.environment(\.colorScheme, scheme).background(.background))
                host.appearance = try #require(NSAppearance(named: appearance))
                host.frame = CGRect(origin: .zero, size: host.fittingSize)
                host.layoutSubtreeIfNeeded()
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                #expect(bitmap.pixelsWide > 0 && bitmap.pixelsHigh > 0)
                if let output {
                    let png = try #require(bitmap.representation(using: .png, properties: [:]))
                    try png.write(to: output.appending(path: "\(name)-\(slug).png"))
                }
            }
        }
    }
}
