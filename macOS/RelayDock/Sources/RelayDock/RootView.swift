import SwiftUI

struct RootView: View {
    @Bindable var model: AppModel

    var body: some View {
        NavigationSplitView {
            List(selection: $model.selection) {
                Section("OpenCode") {
                    ForEach([AppSection.accounts, .usage, .proxies]) { section in
                        Label(section.title, systemImage: section.symbol)
                            .tag(section)
                    }
                }

                Section {
                    Label(AppSection.settings.title, systemImage: AppSection.settings.symbol)
                        .tag(AppSection.settings)
                } header: {
                    Text("Preferences")
                }
            }
            .listStyle(.sidebar)
            .navigationTitle("RelayDock")
            .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 260)
        } detail: {
            Group {
                switch model.selection {
                case .accounts:
                    AccountsView(model: model)
                case .usage:
                    UsageView(model: model)
                case .proxies:
                    ProxiesView(model: model)
                case .settings:
                    SettingsView(model: model)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Label(serverLabel, systemImage: serverSymbol)
                        .foregroundStyle(serverColor)
                        .help(model.serverStatus.error ?? serverDetails)

                    if model.serverBusy {
                        ProgressView()
                            .controlSize(.small)
                    } else if model.serverStatus.running {
                        Button("Stop OpenCode", systemImage: "stop.fill") {
                            Task { await model.stopOpenCode() }
                        }
                        .help("Stop the managed OpenCode server")
                    } else {
                        Button("Start OpenCode", systemImage: "play.fill") {
                            Task { await model.startOpenCode() }
                        }
                        .help("Start OpenCode using the current proxy mode")
                    }
                }
            }
        }
        .navigationSplitViewStyle(.balanced)
        .navigationTitle("RelayDock")
        .preferredColorScheme(colorScheme)
        .task {
            await model.applicationDidLaunch()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(4))
                guard !Task.isCancelled else { break }
                await model.refreshOpenCodeStatus()
            }
        }
        .onDisappear {
            Task { await model.stopOpenCode() }
        }
        .alert("Couldn't Save Settings", isPresented: Binding(
            get: { model.saveError != nil },
            set: { if !$0 { model.clearSaveError() } }
        )) {
            Button("OK", role: .cancel) { model.clearSaveError() }
        } message: {
            Text(model.saveError ?? "Unknown error")
        }
    }

    private var colorScheme: ColorScheme? {
        switch model.settings.theme {
        case "light": .light
        case "dark": .dark
        default: nil
        }
    }

    private var serverLabel: String {
        if model.serverBusy { return model.serverStatus.running ? "Updating OpenCode" : "Starting OpenCode" }
        if model.serverStatus.healthy { return "OpenCode Running" }
        if model.serverStatus.error != nil { return "OpenCode Needs Attention" }
        if model.serverStatus.running { return "OpenCode Not Responding" }
        return "OpenCode Stopped"
    }

    private var serverSymbol: String {
        if model.serverBusy { return "ellipsis.circle" }
        if model.serverStatus.healthy { return "checkmark.circle.fill" }
        if model.serverStatus.error != nil || model.serverStatus.running { return "exclamationmark.circle.fill" }
        return "circle"
    }

    private var serverColor: Color {
        if model.serverStatus.healthy { return .green }
        if model.serverStatus.running || model.serverStatus.error != nil { return .orange }
        return .secondary
    }

    private var serverDetails: String {
        if let error = model.serverStatus.error { return error }
        if let port = model.serverStatus.port { return "Managed OpenCode server on 127.0.0.1:\(port)" }
        return "Managed OpenCode server is stopped"
    }
}

private struct MigrationView: View {
    let title: String
    let subtitle: String
    let symbol: String
    let detail: String

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: symbol)
        } description: {
            Text(subtitle + "\n\n" + detail)
        } actions: {
            Label("Migration in progress", systemImage: "hammer")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(32)
    }
}
