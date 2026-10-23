import Darwin
import Foundation
import RelayDockCore
import SwiftUI

/// Two entry points in one binary: the GUI, and the update helper the GUI
/// spawns right before quitting. Intercepting before SwiftUI starts keeps the
/// helper free of windows, menus, and anything that would keep the app alive.
@main
enum RelayDockMain {
    static func main() {
        if let request = UpdateInstaller.helperRequest(from: CommandLine.arguments) {
            exit(UpdateInstaller.runHelper(request))
        }
        RelayDockApp.main()
    }
}

struct RelayDockApp: App {
    @StateObject private var model = ProxyAppModel()

    var body: some Scene {
        Window("RelayDock", id: "main") {
            RootView(model: model)
        }
        .defaultSize(width: 680, height: 460)
        .windowResizability(.contentMinSize)

        MenuBarExtra {
            MenuBarPanelView(model: model)
        } label: {
            Image(nsImage: MenuBarIcon.image)
                .accessibilityLabel("RelayDock")
        }
        .menuBarExtraStyle(.window)
    }
}
