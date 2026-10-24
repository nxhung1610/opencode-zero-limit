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
        // The sidebar needs room to breathe; the detail still renders a full
        // grouped form at the minimum content size (680×500).
        .defaultSize(width: 760, height: 580)
        .windowResizability(.contentMinSize)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    Task { await model.updates.check(userInitiated: true) }
                }
                .disabled(model.updates.phase == .checking)
            }
        }

        MenuBarExtra {
            MenuBarPanelView(model: model)
        } label: {
            Image(nsImage: MenuBarIcon.image)
                .accessibilityLabel("RelayDock")
        }
        .menuBarExtraStyle(.window)
    }
}
