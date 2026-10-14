import AppKit
import SwiftUI

@MainActor
private enum RelayDockLifecycle {
    static var model: AppModel?
}

@MainActor
private final class RelayDockAppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ notification: Notification) {
        RelayDockLifecycle.model?.terminateManagedProcess()
    }
}

@main
@MainActor
struct RelayDockApp: App {
    @NSApplicationDelegateAdaptor(RelayDockAppDelegate.self) private var appDelegate
    @State private var model: AppModel

    init() {
        let model = AppModel()
        _model = State(initialValue: model)
        RelayDockLifecycle.model = model
    }

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
                .frame(minWidth: 960, minHeight: 640)
        }
        .windowToolbarStyle(.unified)
        .commands {
            SidebarCommands()
        }
    }
}
