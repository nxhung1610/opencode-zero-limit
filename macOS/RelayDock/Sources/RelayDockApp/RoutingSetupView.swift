import AppKit
import RelayDockCore
import SwiftUI

/// The Routing tab's setup card: install the PATH wrapper from the app, keep
/// its components in step with this build, and verify that new terminals
/// resolve `opencode` to the wrapper. Nothing here edits shell profiles; the
/// app only ever copies a snippet.
struct RoutingSetupView: View {
    @ObservedObject var model: RoutingSetupModel

    @State private var copiedSnippet = false
    @State private var copiedServiceHint = false

    private static let pathSnippet = #"export PATH="$HOME/.local/bin:$PATH""#
    private static let serviceHintCommand = "opencode service stop && opencode service start"

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            switch model.state {
            case .checking:
                Text("Checking…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .unavailable:
                caption("This build has no bundled routing components; build with scripts/build-macos-app.sh to include them.")
            case .notInstalled:
                notInstalledBody
            case .installed(let installation):
                installedBody(installation)
            }
            if let errorMessage = model.errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 2)
        .confirmationDialog(
            "Remove routing setup?",
            isPresented: $model.isUninstallPresented
        ) {
            Button("Remove Routing", role: .destructive) {
                Task { await model.uninstall() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("RelayDock removes the launchd agent, ~/.local/bin/relaydock-launch and relaydock-edge, the ~/.local/bin/opencode symlink, and edge.json. Your proxy pool and Edge's script cache are kept; OpenCode data is never touched.")
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "terminal")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(headerTint)
            VStack(alignment: .leading, spacing: 2) {
                Text("Routing setup")
                    .font(.callout.weight(.semibold))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(needsAttention ? Color.orange : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var subtitle: String {
        switch model.state {
        case .checking:
            "Checking…"
        case .unavailable:
            "Unavailable in this build"
        case .notInstalled:
            "Opt-in: send new terminal opencode launches through Edge"
        case .installed(let installation):
            if installation.componentsOutOfDate {
                "Installed — components differ from this app's build"
            } else if !installation.agentPlistInstalled {
                "Installed — the login agent is missing"
            } else {
                "Installed — new terminal launches route through Edge"
            }
        }
    }

    private var headerTint: Color {
        switch model.state {
        case .checking, .unavailable, .notInstalled:
            .secondary
        case .installed:
            needsAttention ? .orange : .green
        }
    }

    private var needsAttention: Bool {
        switch model.state {
        case .installed(let installation):
            return installation.componentsOutOfDate
                || !installation.agentPlistInstalled
                || model.pathCheck.isAttention
        case .checking, .unavailable, .notInstalled:
            return false
        }
    }

    // MARK: - Not installed

    private var notInstalledBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("RelayDock installs a small launcher into ~/.local/bin. New terminals launched afterwards route opencode through Edge; already-open terminals keep their current environment.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            installButton(title: "Install Routing")
            whatItWrites
        }
    }

    private func installButton(title: String) -> some View {
        Button {
            Task { await model.install() }
        } label: {
            if model.activity == .installing {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Installing…")
                }
            } else {
                Text(title)
            }
        }
        .appAction(.primary, size: .large)
        .disabled(model.activity != .idle)
    }

    private var whatItWrites: some View {
        DisclosureGroup("What it writes") {
            VStack(alignment: .leading, spacing: 5) {
                writtenPath("~/.local/bin/relaydock-launch", "the launcher the opencode symlink points at")
                writtenPath("~/.local/bin/relaydock-edge", "the tunnel daemon")
                writtenPath("~/.local/bin/opencode", "a symlink to the launcher; an existing non-symlink opencode is never replaced")
                writtenPath("~/Library/LaunchAgents/com.nxhung.relaydock.edge.plist", "the login agent that keeps Edge available")
                writtenPath("edge.json", "Edge's loopback port — written once, kept on reinstall")
            }
            .padding(.top, 4)
        }
        .font(.caption)
    }

    private func writtenPath(_ path: String, _ note: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(path)
                .font(.caption.monospaced())
            Text(note)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Installed

    private func installedBody(_ installation: RoutingSetupModel.Installation) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if installation.componentsOutOfDate {
                attentionRow(
                    "The installed components differ from this app's build.",
                    actionTitle: "Update Components"
                )
            } else if !installation.agentPlistInstalled {
                attentionRow(
                    "The login agent is missing; Edge will start on demand only.",
                    actionTitle: "Repair Install"
                )
            }
            LabeledContent("Login agent") {
                Text(installation.agentPlistInstalled ? "Installed" : "Missing")
                    .foregroundStyle(installation.agentPlistInstalled ? Color.primary : Color.orange)
            }
            pathRow
            serviceHint
            HStack(spacing: 10) {
                Button {
                    model.isUninstallPresented = true
                } label: {
                    if model.activity == .uninstalling {
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Removing…")
                        }
                    } else {
                        Text("Uninstall…")
                    }
                }
                .appAction(.secondary, size: .large)
                .disabled(model.activity != .idle)
            }
        }
    }

    private func attentionRow(_ message: String, actionTitle: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button(actionTitle) {
                Task { await model.install() }
            }
            .appAction(.secondary)
            .disabled(model.activity != .idle)
        }
    }

    @ViewBuilder
    private var pathRow: some View {
        switch model.pathCheck {
        case .unchecked:
            LabeledContent("New terminals") {
                HStack(spacing: 10) {
                    Text("Not verified yet")
                        .foregroundStyle(.secondary)
                    verifyButton
                }
            }
        case .ok:
            LabeledContent("New terminals") {
                Label("opencode resolves to the wrapper", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
        case .notFound:
            pathWarning("New terminals don't find opencode yet. Add ~/.local/bin to PATH for new shells:")
        case .shadowed(let resolved):
            pathWarning("New terminals resolve opencode to \(resolved) — an earlier PATH entry wins. Put ~/.local/bin first:")
        }
    }

    private func pathWarning(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Text(Self.pathSnippet)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                copyButton(copied: $copiedSnippet, text: Self.pathSnippet)
                Spacer(minLength: 0)
                verifyButton
            }
        }
    }

    private var verifyButton: some View {
        Button {
            Task { await model.verifyPath() }
        } label: {
            if model.activity == .verifying {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Verifying…")
                }
            } else {
                Text("Verify")
            }
        }
        .appAction(.link)
        .disabled(model.activity != .idle)
    }

    private var serviceHint: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("OpenCode's background service keeps its old environment until restarted — do this when no session is active:")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Text(Self.serviceHintCommand)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                copyButton(copied: $copiedServiceHint, text: Self.serviceHintCommand)
            }
        }
    }

    // MARK: - Helpers

    private func copyButton(copied: Binding<Bool>, text: String) -> some View {
        Button(copied.wrappedValue ? "Copied" : "Copy") {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            copied.wrappedValue = true
            Task {
                try? await Task.sleep(for: .seconds(2))
                copied.wrappedValue = false
            }
        }
        .appAction(.link)
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private extension RoutingSetupModel.PathCheck {
    var isAttention: Bool {
        switch self {
        case .notFound, .shadowed: true
        case .unchecked, .ok: false
        }
    }
}
