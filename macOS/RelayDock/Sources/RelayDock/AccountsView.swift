import AppKit
import RelayDockCore
import SwiftUI

struct AccountsView: View {
    @Bindable var model: AppModel
    @State private var removalTarget: ConsoleConnection?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                PageHeader(
                    title: "Accounts",
                    subtitle: "Manage OpenCode Console sign-ins. Credentials stay in OpenCode’s local store."
                ) {
                    HStack(spacing: 8) {
                        Button {
                            Task { await model.refreshConsoleConnections() }
                        } label: {
                            if model.accountsLoading {
                                ProgressView().controlSize(.small)
                                    .frame(width: 16, height: 16)
                            } else {
                                Image(systemName: "arrow.clockwise")
                            }
                        }
                        .buttonStyle(.bordered)
                        .disabled(model.accountsLoading || !model.supportsConsoleAccounts)
                        .help("Reload saved Console accounts")
                        .accessibilityLabel("Reload accounts")

                        Button {
                            beginSignIn()
                        } label: {
                            Label("Add Account", systemImage: "plus")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.accountsBusy || model.accountsLoading || model.loginAttempt != nil || !model.supportsConsoleAccounts)
                    }
                    .controlSize(.regular)
                }

                if let notice = model.accountNotice {
                    Label(notice, systemImage: "info.circle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityAddTraits(.updatesFrequently)
                }

                if let error = model.accountError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityAddTraits(.updatesFrequently)
                }

                if let attempt = model.loginAttempt {
                    signInCard(attempt)
                }

                if !model.serverStatus.healthy {
                    serverUnavailableState
                    .frame(minHeight: 220)
                } else if !model.supportsConsoleAccounts {
                    ContentUnavailableView(
                        "OpenCode v2 Required",
                        systemImage: "person.crop.circle.badge.exclamationmark",
                        description: Text("Browser-based Console account management requires OpenCode CLI v2. Detected version: \(model.serverStatus.version ?? "unknown").")
                    )
                    .frame(minHeight: 220)
                } else {
                    accountInventory
                }
            }
            .frame(maxWidth: 860, alignment: .leading)
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .task(id: taskKey) {
            await model.refreshConsoleConnections()
            guard let attemptID = model.loginAttempt?.attemptID else { return }
            while !Task.isCancelled, model.loginAttempt?.attemptID == attemptID {
                do {
                    try await Task.sleep(for: .milliseconds(1_500))
                } catch {
                    return
                }
                guard !Task.isCancelled, model.loginAttempt?.attemptID == attemptID else { return }
                await model.pollConsoleLogin()
            }
        }
        .confirmationDialog(
            "Remove Console Account?",
            isPresented: Binding(
                get: { removalTarget != nil },
                set: { if !$0 { removalTarget = nil } }
            ),
            titleVisibility: .visible,
            presenting: removalTarget
        ) { connection in
            Button("Remove \(connection.label)", role: .destructive) {
                Task { await model.removeConsoleConnection(connection) }
                removalTarget = nil
            }
            Button("Cancel", role: .cancel) { removalTarget = nil }
        } message: { connection in
            Text("OpenCode will remove this locally saved credential. This action cannot be undone from RelayDock.")
        }
    }

    @ViewBuilder
    private var serverUnavailableState: some View {
        ContentUnavailableView {
            Label(
                model.serverStatus.error == nil ? "OpenCode Is Stopped" : "OpenCode Couldn’t Start",
                systemImage: model.serverStatus.error == nil ? "power" : "exclamationmark.triangle"
            )
        } description: {
            VStack(spacing: 6) {
                Text(model.serverStatus.error ?? "Start the managed server to load or connect Console accounts.")
                Text("RelayDock keeps the server local to this Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } actions: {
            HStack(spacing: 8) {
                Button("Start OpenCode", systemImage: "play.fill") {
                    Task { await model.startOpenCode() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.serverBusy)

                if model.serverStatus.error?.localizedCaseInsensitiveContains("proxy") == true {
                    Button("Review Proxies", systemImage: "network") {
                        model.selection = .proxies
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }

    @ViewBuilder
    private var accountInventory: some View {
        if model.accountsLoading && model.consoleConnections.isEmpty {
            ProgressView("Loading saved Console accounts…")
                .frame(maxWidth: .infinity, minHeight: 180)
        } else if model.accountError != nil && model.consoleConnections.isEmpty {
            ContentUnavailableView {
                Label("Couldn't Load Accounts", systemImage: "exclamationmark.icloud")
            } description: {
                Text("Check that the local OpenCode server is healthy, then reload.")
            } actions: {
                Button("Try Again") { Task { await model.refreshConsoleConnections() } }
                    .buttonStyle(.bordered)
                    .disabled(model.accountsLoading)
            }
            .frame(minHeight: 220)
        } else if model.consoleConnections.isEmpty {
            ContentUnavailableView {
                Label("No Console Accounts", systemImage: "person.crop.circle.badge.plus")
            } description: {
                Text("Add an account to start browser authorization. OpenCode stores the credential locally; RelayDock never reads the secret value.")
            } actions: {
                Button("Add Account") {
                    Task {
                        await model.startConsoleLogin()
                        if let url = model.loginAttempt?.url { NSWorkspace.shared.open(url) }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.accountsBusy || model.loginAttempt != nil)
            }
            .frame(minHeight: 220)
        } else {
            GroupBox {
                VStack(spacing: 0) {
                    ForEach(Array(model.consoleConnections.enumerated()), id: \.element.id) { index, connection in
                        connectionRow(connection)
                        if index < model.consoleConnections.count - 1 {
                            Divider().padding(.leading, 46)
                        }
                    }
                }
            }
            label: {
                HStack {
                    Label("Saved Accounts", systemImage: "person.2")
                    Text(model.consoleConnections.count.formatted())
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Spacer()
                    if let active = model.consoleConnections.first(where: \.active) {
                        Label("Active · \(active.label)", systemImage: "checkmark.circle.fill")
                            .font(.callout)
                            .foregroundStyle(.green)
                    } else {
                        Label("No active account", systemImage: "minus.circle")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Label("OpenCode stores credentials in its local database. RelayDock only uses safe connection metadata; it never displays or stores credential values.", systemImage: "lock.shield")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
        }
    }

    private func connectionRow(_ connection: ConsoleConnection) -> some View {
        HStack(spacing: 12) {
            Image(systemName: connection.active ? "person.crop.circle.badge.checkmark" : "person.crop.circle")
                .font(.title2)
                .foregroundStyle(connection.active ? .green : .secondary)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 3) {
                Text(connection.label)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Text("OpenCode Console · saved locally")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            if connection.active {
                Label("Active", systemImage: "checkmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(.green)
            } else {
                Button("Use Account") {
                    Task { await model.activateConsoleConnection(connection) }
                }
                .buttonStyle(.bordered)
                .disabled(model.accountsBusy || model.serverBusy)
            }

            Button(role: .destructive) {
                removalTarget = connection
            } label: {
                Image(systemName: "trash")
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.borderless)
            .disabled(model.accountsBusy || model.serverBusy)
            .help("Remove \(connection.label)")
            .accessibilityLabel("Remove \(connection.label)")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .contentShape(Rectangle())
    }

    private func signInCard(_ attempt: ConsoleLoginAttempt) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                Text(attempt.instructions)
                    .font(.callout)
                    .foregroundStyle(.secondary)

                HStack(spacing: 10) {
                    Button {
                        NSWorkspace.shared.open(attempt.url)
                    } label: {
                        Label("Open Sign-In in Browser", systemImage: "safari")
                    }
                    .buttonStyle(.borderedProminent)

                    Button("Cancel", role: .cancel) {
                        Task { await model.cancelConsoleLogin() }
                    }
                    .disabled(model.accountsBusy)

                    Spacer()

                    Label("Waiting for authorization…", systemImage: "hourglass")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if attempt.mode == .code {
                    HStack(alignment: .bottom, spacing: 10) {
                        SecureField("Authorization code", text: $model.loginCode)
                            .textFieldStyle(.roundedBorder)
                            .textContentType(.oneTimeCode)
                        Button("Submit Code") {
                            Task { await model.completeConsoleLogin() }
                        }
                        .disabled(model.accountsBusy || model.loginCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    .frame(maxWidth: 480)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        } label: {
            Label("Finish Browser Sign-In", systemImage: "person.crop.circle.badge.checkmark")
                .font(.headline)
        }
    }

    private func beginSignIn() {
        Task {
            await model.startConsoleLogin()
            if let url = model.loginAttempt?.url { NSWorkspace.shared.open(url) }
        }
    }

    private var taskKey: String {
        "\(model.accountServerKey)-\(model.loginAttempt?.attemptID ?? "no-attempt")"
    }
}
