import AppKit
import RelayDockCore
import SwiftUI

enum RoutingChangeSource: Equatable {
    case window
    case menu
    case manualChooser
}

struct PendingRoutingChange: Identifiable, Equatable {
    let id: UUID
    let mode: ProxyMode
    let manualID: String?
    let previousMode: ProxyMode
    let previousManualID: String?
    let source: RoutingChangeSource
    let report: OpenCodeRoutingSnapshot
}

/// A shared presenter, scoped to the initiating surface so opening the menu
/// alongside the window cannot present the same warning twice. A chooser may
/// present it without dismissing itself (Cancel keeps the selection available).
struct RoutingModeWarningPresenter: ViewModifier {
    @ObservedObject var model: ProxyAppModel
    let source: RoutingChangeSource

    func body(content: Content) -> some View {
        content.sheet(item: Binding(
            get: { model.pendingRoutingChange.flatMap { $0.source == source ? $0 : nil } },
            set: { value in
                if value == nil, let request = model.pendingRoutingChange, request.source == source {
                    model.cancelRoutingChange(request.id)
                }
            }
        )) { request in
            RoutingModeWarningView(
                request: request,
                cancel: { model.cancelRoutingChange(request.id) },
                confirm: { model.confirmRoutingChange(request) }
            )
        }
    }
}

struct RoutingModeWarningView: View {
    let request: PendingRoutingChange
    let cancel: () -> Void
    let confirm: () -> Void
    @State private var showsRecovery = false

    init(request: PendingRoutingChange, showsRecovery: Bool = false, cancel: @escaping () -> Void, confirm: @escaping () -> Void) {
        self.request = request
        self.cancel = cancel
        self.confirm = confirm
        _showsRecovery = State(initialValue: showsRecovery)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label {
                Text("Some OpenCode sessions may not follow this mode")
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.primary)
            }
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
            Text("\(request.report.affectedServers.count) running OpenCode server\(request.report.affectedServers.count == 1 ? " hasn't" : "s haven't") received a usable Edge proxy environment. Sessions served by \(request.report.affectedServers.count == 1 ? "it" : "them") may keep their existing route after switching to \(request.mode.rawValue.capitalized).")
                .fixedSize(horizontal: false, vertical: true)
            ForEach(request.report.affectedServers.prefix(5), id: \.pid) { server in
                Text("PID \(String(server.pid)) · \(routingReason(server.route))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if request.report.affectedServers.count > 5 {
                Text("And \(request.report.affectedServers.count - 5) more servers.").font(.caption)
            }
            Text("The mode has not changed. Continuing only saves the policy; no service or session will be restarted.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            if showsRecovery {
                Text("Save the selected mode with Change Mode Anyway before following these steps.")
                    .font(.caption)
                RoutingRecoveryInstructions()
            }
            HStack {
                Button(showsRecovery ? "Hide Steps" : "How to Fix…") { showsRecovery.toggle() }
                    .appAction(.link)
                Spacer()
                Button("Cancel", action: cancel)
                    .keyboardShortcut(.cancelAction)
                Button("Change Mode Anyway", action: confirm)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 500)
    }
}

/// Persistent until a later inspection no longer finds the issue; absence of
/// recent tunnels never triggers this notice or the mode-change popup.
struct OpenCodeRoutingNotice: View {
    @ObservedObject var model: ProxyAppModel
    var compact = false
    @State private var showsHelp = false

    var body: some View {
        if model.isCheckingOpenCodeRouting {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Checking running OpenCode servers…").font(.caption)
            }
        } else if model.hasOpenCodeRoutingNotice, let report = model.openCodeRouting {
            VStack(alignment: .leading, spacing: 6) {
                Label {
                    Text(report.affectedServers.isEmpty
                        ? "OpenCode routing couldn't be verified"
                        : "\(report.affectedServers.count) OpenCode server\(report.affectedServers.count == 1 ? " may" : "s may") not follow this mode")
                        .font(.callout.weight(.medium))
                } icon: {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.primary)
                }
                .fixedSize(horizontal: false, vertical: true)
                if !compact {
                    Text("The saved mode does not update an already-running server's proxy environment. This check covers native local servers, not remote or embedded SDK servers.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 14) {
                    Button("How to Fix…") { showsHelp = true }.appAction(.link, size: .small)
                    Button("Check Again") { Task { await model.refreshOpenCodeRouting(force: true) } }
                        .appAction(.link, size: .small)
                }
            }
            .font(.callout)
            .padding(.vertical, compact ? 2 : 0)
            .frame(maxWidth: .infinity, alignment: .leading)
            .sheet(isPresented: $showsHelp) {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Apply routing to OpenCode").font(.title3.weight(.semibold))
                    RoutingRecoveryInstructions()
                    HStack {
                        Spacer()
                        Button("Done") { showsHelp = false }.keyboardShortcut(.cancelAction)
                    }
                }
                .padding(24)
                .frame(width: 500)
            }
        }
    }
}

private struct RoutingRecoveryInstructions: View {
    private static let command = "opencode service stop && opencode service start"
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("In a terminal, first verify that `command -v opencode` points to ~/.local/bin/opencode. Install or repair Routing setup if needed.")
            Text("After selecting Manual or Auto, run this only when no session is active. It stops the shared service and can interrupt sessions. RelayDock will not run it for you.")
            Text(Self.command).font(.caption.monospaced()).textSelection(.enabled)
            Button(copied ? "Copied" : "Copy Command") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(Self.command, forType: .string)
                copied = true
            }
            Text("For a standalone server, relaunch that server through the wrapper instead. If process inspection was unavailable, an administrator policy or macOS restriction may prevent verification.")
                .foregroundStyle(.secondary)
        }
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private func routingReason(_ route: OpenCodeRoutingSnapshot.Route) -> String {
    switch route {
    case .missingProxy: "No proxy environment at startup"
    case .otherProxy: "Proxy environment points to a different endpoint"
    case .bypassAll: "NO_PROXY=* bypasses proxy routing"
    case .unverified: "Proxy environment could not be verified"
    case .edgeEnvironment: "Edge environment present; traffic not verified"
    }
}
