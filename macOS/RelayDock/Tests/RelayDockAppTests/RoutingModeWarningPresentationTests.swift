import AppKit
import Foundation
import RelayDockCore
import SwiftUI
import Testing
@testable import RelayDockApp

@MainActor
struct RoutingModeWarningPresentationTests {
    @Test func warningIsPresentedOnlyByItsInitiatingSurface() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ProxyStore(configDirectory: directory)
        let imported = try store.importProxies("http://proxy.example:8080")
        let model = ProxyAppModel(store: store, routingProbe: { _ in
            .init(servers: [.init(pid: 10, startedAt: 1, route: .missingProxy)])
        })
        model.load()
        // Offscreen native windows exercise sheet presentation without touching
        // real sessions, starting Edge, or running OpenCode commands.
        let main = window(WarningPresentationHarness(model: model, source: .window), width: 680)
        let menu = window(WarningPresentationHarness(model: model, source: .menu), width: 360)
        defer { main.close(); menu.close() }

        await model.selectMode(.auto, source: .menu)
        await settle { menu.attachedSheet != nil }
        #expect(menu.attachedSheet != nil)
        #expect(main.attachedSheet == nil)
        model.cancelRoutingChange(try #require(model.pendingRoutingChange).id)
        await settle { menu.attachedSheet == nil }
        #expect(try store.load().mode == .off)

        await model.selectMode(.auto, source: .window)
        await settle { main.attachedSheet != nil }
        #expect(main.attachedSheet != nil)
        #expect(menu.attachedSheet == nil)
        model.cancelRoutingChange(try #require(model.pendingRoutingChange).id)
        await settle { main.attachedSheet == nil }

        await model.selectMode(.manual)
        await settle { main.attachedSheet != nil }
        let chooser = try #require(main.attachedSheet)
        await model.selectManualProxy(imported.proxies[0].id, source: .manualChooser)
        await settle { chooser.attachedSheet != nil }
        #expect(chooser.attachedSheet != nil)
        #expect(menu.attachedSheet == nil)
        model.cancelRoutingChange(try #require(model.pendingRoutingChange).id)
        await settle { chooser.attachedSheet == nil }
        #expect(model.isManualChooserPresented)
        #expect(try store.load().mode == .off)
        model.isManualChooserPresented = false
        await settle { main.attachedSheet == nil }
    }

    private func window<Content: View>(_ view: Content, width: Double) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: -10_000, y: -10_000, width: width, height: 400),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: view)
        window.orderFront(nil)
        return window
    }

    private func settle(until condition: () -> Bool) async {
        for _ in 0..<75 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }
}

private struct WarningPresentationHarness: View {
    @ObservedObject var model: ProxyAppModel
    let source: RoutingChangeSource

    var body: some View {
        Text("Routing surface")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .modifier(RoutingModeWarningPresenter(model: model, source: source))
            .sheet(isPresented: Binding(
                get: { source == .window && model.isManualChooserPresented },
                set: { model.isManualChooserPresented = $0 }
            )) {
                Text("Manual chooser")
                    .frame(width: 420, height: 330)
                    .modifier(RoutingModeWarningPresenter(model: model, source: .manualChooser))
            }
    }
}
