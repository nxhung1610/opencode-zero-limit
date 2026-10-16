import SwiftUI

@main
struct RelayDockApp: App {
    @StateObject private var model = ProxyAppModel()

    var body: some Scene {
        Window("RelayDock", id: "main") {
            RootView(model: model)
        }
        .defaultSize(width: 680, height: 460)
        .windowResizability(.contentMinSize)

        MenuBarExtra("RelayDock", systemImage: "arrow.left.arrow.right") {
            MenuBarPanelView(model: model)
        }
        .menuBarExtraStyle(.window)
    }
}
