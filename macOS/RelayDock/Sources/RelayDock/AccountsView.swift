import AppKit
import RelayDockCore
import SwiftUI

struct AccountsView: View {
    @Bindable var model: AppModel
    @State private var selectedAccountID: String?
    @State private var removalTarget: ConsoleConnection?

    var body: some View {
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

                    Button(action: beginSignIn) {
                        Label("Add Account", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.accountsBusy || model.accountsLoading || model.loginAttempt != nil || !model.supportsConsoleAccounts)
                }
                .controlSize(.regular)
            }

            accountWorkspace
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.background)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(.quaternary, lineWidth: 1)
                }
        }
        .padding(24)
        .frame(maxWidth: 1040, maxHeight: .infinity, alignment: .top)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task(id: taskKey) {
            await model.refreshConsoleConnections()
            selectDefaultAccount()
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
        .onChange(of: model.consoleConnections.map(\.id)) { _, _ in
            selectDefaultAccount()
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

    private var accountWorkspace: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 0) {
                accountList
                    .frame(width: 210)

                Divider()

                accountDetailScrollView
                    .frame(minWidth: 400)
            }
            .frame(minWidth: 612)

            VStack(alignment: .leading, spacing: 0) {
                if !model.consoleConnections.isEmpty {
                    Picker("Account", selection: $selectedAccountID) {
                        ForEach(model.consoleConnections) { connection in
                            Text(connection.label).tag(Optional(connection.id))
                        }
                    }
                    .pickerStyle(.menu)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)

                    Divider()
                }

                accountDetailScrollView
            }
        }
    }

    private var accountDetailScrollView: some View {
        ScrollView {
            accountDetails
                .frame(maxWidth: .infinity, minHeight: 320, alignment: .topLeading)
                .padding(20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var accountList: some View {
        List(selection: $selectedAccountID) {
            Section {
                if model.consoleConnections.isEmpty {
                    Text(model.accountsLoading ? "Loading accounts…" : "No saved accounts")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.consoleConnections) { connection in
                        Label {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(connection.label)
                                    .lineLimit(1)
                                Text(connection.active ? "Active account" : "Saved locally")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: connection.active ? "person.crop.circle.badge.checkmark" : "person.crop.circle")
                                .foregroundStyle(connection.active ? .green : .secondary)
                        }
                        .tag(connection.id)
                    }
                }
            } header: {
                HStack {
                    Text("Saved Accounts")
                    Spacer(minLength: 4)
                    Text(model.consoleConnections.count.formatted())
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
    }

    @ViewBuilder
    private var accountDetails: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let notice = model.accountNotice {
                Label(notice, systemImage: "info.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .accessibilityAddTraits(.updatesFrequently)
            }

            if let error = model.accountError, model.serverStatus.healthy {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .accessibilityAddTraits(.updatesFrequently)
            }

            if let attempt = model.loginAttempt {
                signInCard(attempt)
            } else if !model.serverStatus.healthy {
                serverUnavailableState
            } else if !model.supportsConsoleAccounts {
                ContentUnavailableView(
                    "OpenCode v2 Required",
                    systemImage: "person.crop.circle.badge.exclamationmark",
                    description: Text("Browser-based Console account management requires OpenCode CLI v2. Detected version: \(model.serverStatus.version ?? "unknown").")
                )
                .frame(maxWidth: .infinity, minHeight: 240)
            } else if model.accountsLoading && model.consoleConnections.isEmpty {
                ProgressView("Loading saved Console accounts…")
                    .frame(maxWidth: .infinity, minHeight: 240)
            } else if model.accountError != nil && model.consoleConnections.isEmpty {
                ContentUnavailableView {
                    Label("Couldn’t Load Accounts", systemImage: "exclamationmark.icloud")
                } description: {
                    Text("Check the local OpenCode server, then try loading accounts again.")
                } actions: {
                    Button("Try Again", systemImage: "arrow.clockwise") {
                        Task { await model.refreshConsoleConnections() }
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.accountsLoading)
                }
                .frame(maxWidth: .infinity, minHeight: 240)
            } else if model.consoleConnections.isEmpty {
                ContentUnavailableView {
                    Label("No Console Account Selected", systemImage: "person.crop.circle.badge.plus")
                } description: {
                    Text("Add an account to authorize in your browser. OpenCode keeps the credential locally.")
                } actions: {
                    Button("Add Account", systemImage: "plus", action: beginSignIn)
                        .buttonStyle(.borderedProminent)
                        .disabled(model.accountsBusy || model.loginAttempt != nil)
                }
                .frame(maxWidth: .infinity, minHeight: 240)
            } else if let connection = selectedConnection {
                connectionDetails(connection)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var serverUnavailableState: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(
                model.serverStatus.error == nil ? "OpenCode Is Stopped" : "OpenCode Needs Attention",
                systemImage: model.serverStatus.error == nil ? "power" : "exclamationmark.triangle.fill"
            )
            .font(.headline)

            Text(model.serverStatus.error ?? "Start the managed server to load or connect Console accounts.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

            Label("The managed server is local to this Mac.", systemImage: "lock.shield")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                if hasProxyStartError {
                    Button("Review Proxies", systemImage: "network") {
                        model.selection = .proxies
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Button("Start OpenCode", systemImage: "play.fill") {
                        Task { await model.startOpenCode() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.serverBusy)
                }
            }
            .padding(.top, 2)
        }
        .frame(maxWidth: 540, minHeight: 270, alignment: .leading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private func connectionDetails(_ connection: ConsoleConnection) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: connection.active ? "person.crop.circle.badge.checkmark" : "person.crop.circle")
                    .font(.system(size: 32, weight: .regular))
                    .foregroundStyle(connection.active ? .green : .secondary)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 5) {
                    Text(connection.label)
                        .font(.title3.weight(.semibold))
                        .lineLimit(1)
                    Text("OpenCode Console · saved locally")
                        .font(.callout)
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
                    .buttonStyle(.borderedProminent)
                    .disabled(model.accountsBusy || model.serverBusy)
                }
            }

            Divider()

            VStack(spacing: 12) {
                LabeledContent("Provider") {
                    Text("OpenCode Console")
                }
                LabeledContent("Credential storage") {
                    Text("OpenCode local database")
                }
                LabeledContent("RelayDock access") {
                    Label("Metadata only", systemImage: "lock.shield")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.callout)
            .frame(maxWidth: 560, alignment: .leading)

            Divider()

            Text("OpenCode owns the credential. RelayDock never displays or stores the secret value.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button("Remove Account", systemImage: "trash", role: .destructive) {
                removalTarget = connection
            }
            .buttonStyle(.borderless)
            .disabled(model.accountsBusy || model.serverBusy)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func signInCard(_ attempt: ConsoleLoginAttempt) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Finish Browser Sign-In", systemImage: "person.crop.circle.badge.checkmark")
                .font(.headline)

            Text(attempt.instructions)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

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
            }

            Label("Waiting for authorization…", systemImage: "hourglass")
                .font(.caption)
                .foregroundStyle(.secondary)

            if attempt.mode == .code {
                VStack(alignment: .leading, spacing: 8) {
                    SecureField("Authorization code", text: $model.loginCode)
                        .textFieldStyle(.roundedBorder)
                        .textContentType(.oneTimeCode)
                    Button("Submit Code") {
                        Task { await model.completeConsoleLogin() }
                    }
                    .disabled(model.accountsBusy || model.loginCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .frame(maxWidth: 420, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var selectedConnection: ConsoleConnection? {
        if let selectedAccountID,
           let selected = model.consoleConnections.first(where: { $0.id == selectedAccountID }) {
            return selected
        }
        return model.consoleConnections.first(where: \.active) ?? model.consoleConnections.first
    }

    private var hasProxyStartError: Bool {
        model.serverStatus.error?.localizedCaseInsensitiveContains("proxy") == true
    }

    private var taskKey: String {
        "\(model.accountServerKey)-\(model.loginAttempt?.attemptID ?? "no-attempt")"
    }

    private func selectDefaultAccount() {
        guard !model.consoleConnections.isEmpty else {
            selectedAccountID = nil
            return
        }
        if let selectedAccountID,
           model.consoleConnections.contains(where: { $0.id == selectedAccountID }) {
            return
        }
        selectedAccountID = model.consoleConnections.first(where: \.active)?.id ?? model.consoleConnections.first?.id
    }

    private func beginSignIn() {
        Task {
            await model.startConsoleLogin()
            if let url = model.loginAttempt?.url { NSWorkspace.shared.open(url) }
        }
    }
}
