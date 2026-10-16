import SwiftUI

@main
struct RelayDockApp: App {
    @StateObject private var model = ProxyAppModel()

    var body: some Scene {
        WindowGroup("RelayDock") {
            RootView(model: model)
        }
        .defaultSize(width: 680, height: 460)
        .windowResizability(.contentMinSize)
    }
}
