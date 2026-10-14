import RelayDockCore
import SwiftUI

private enum ProxyInspectorPanel: String, CaseIterable, Identifiable {
    case routing
    case pool
    case importURLs

    var id: Self { self }

    var title: String {
        switch self {
        case .routing: "Routing Policy"
        case .pool: "Proxy Pool"
        case .importURLs: "Import Proxies"
        }
    }

    var symbol: String {
        switch self {
        case .routing: "arrow.left.arrow.right"
        case .pool: "server.rack"
        case .importURLs: "square.and.arrow.down"
        }
    }
}

struct ProxiesView: View {
    @Bindable var model: AppModel
    @State private var importText = ""
    @State private var selectedPanel: ProxyInspectorPanel = .routing

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PageHeader(
                title: "Proxies",
                subtitle: "Choose how the managed OpenCode process connects to the network."
            ) {
                EmptyView()
            }

            proxyWorkspace
            .frame(minHeight: 400)
            .background(.background)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(.quaternary, lineWidth: 1)
            }
        }
        .padding(24)
        .frame(maxWidth: 1080, maxHeight: .infinity, alignment: .top)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .disabled(model.serverBusy)
        .alert("Proxy Error", isPresented: Binding(
            get: { model.proxyError != nil },
            set: { if !$0 { model.clearProxyError() } }
        )) {
            Button("OK", role: .cancel) { model.clearProxyError() }
        } message: {
            Text(model.proxyError ?? "Unknown error")
        }
    }

    private var proxyWorkspace: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 0) {
                proxyPanelList
                    .frame(width: 180)

                Divider()

                proxyPanelDetail
                    .frame(minWidth: 400)
            }
            .frame(minWidth: 621)

            VStack(alignment: .leading, spacing: 0) {
                proxyPanelPicker
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)

                Divider()

                proxyPanelDetail
            }
        }
    }

    private var proxyPanelList: some View {
        List(selection: $selectedPanel) {
            Section("Proxy Setup") {
                ForEach(ProxyInspectorPanel.allCases) { panel in
                    Label(panel.title, systemImage: panel.symbol)
                        .tag(panel)
                }
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
    }

    private var proxyPanelPicker: some View {
        Picker("Proxy Setup", selection: $selectedPanel) {
            ForEach(ProxyInspectorPanel.allCases) { panel in
                Text(panel.title).tag(panel)
            }
        }
        .pickerStyle(.menu)
    }

    private var proxyPanelDetail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                switch selectedPanel {
                case .routing:
                    routingSection
                case .pool:
                    proxyPoolSection
                case .importURLs:
                    importSection
                }
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var routingSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                Picker("Proxy mode", selection: Binding(
                    get: { model.proxyState.mode },
                    set: { model.setProxyMode($0) }
                )) {
                    Text("Off").tag(ProxyMode.off)
                    Text("Manual").tag(ProxyMode.manual)
                    Text("Auto").tag(ProxyMode.auto)
                }
                .pickerStyle(.segmented)

                if model.proxyState.mode == .manual {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Selected proxy")
                            .font(.callout)
                            .foregroundStyle(.secondary)

                        Picker("Selected proxy", selection: Binding(
                            get: { model.proxyState.manualId ?? "" },
                            set: { model.chooseManualProxy($0) }
                        )) {
                            Text("Choose a proxy").tag("")
                            ForEach(model.proxyState.proxies) { proxy in
                                Text(proxy.label).tag(proxy.id)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                Label(modeDescription, systemImage: modeSymbol)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 3)
        } label: {
            Label("Routing Policy", systemImage: "arrow.left.arrow.right")
        }
    }

    private var proxyPoolSection: some View {
        GroupBox {
            if model.proxyState.proxies.isEmpty {
                ContentUnavailableView(
                    "No Proxies Yet",
                    systemImage: "network",
                    description: Text("Import one or more proxy URLs below to use Manual or Auto routing.")
                )
                .frame(minHeight: 150)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(model.proxyState.proxies.enumerated()), id: \.element.id) { index, proxy in
                        proxyRow(proxy)
                        if index < model.proxyState.proxies.count - 1 {
                            Divider().padding(.leading, 28)
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 10) {
                Label("Proxy Pool", systemImage: "server.rack")
                Text(model.proxyState.proxies.count.formatted())
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()

                Button {
                    Task { await model.checkAllProxies() }
                } label: {
                    if model.checkingProxies {
                        ProgressView().controlSize(.small)
                            .frame(width: 16, height: 16)
                    } else {
                        Label("Test Enabled", systemImage: "bolt.horizontal")
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(model.checkingProxies || !model.proxyState.proxies.contains(where: \.enabled))
                .help("Test enabled proxies through the proxies themselves")

                Button {
                    model.refreshProxies()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(model.checkingProxies)
                .help("Reload saved proxies")
                .accessibilityLabel("Reload proxies")
            }
        }
    }

    private var importSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                TextEditor(text: $importText)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 92, maxHeight: 140)
                    .overlay(alignment: .topLeading) {
                        if importText.isEmpty {
                            Text("http://user:password@proxy.example:8080\nsocks5://127.0.0.1:1080")
                                .font(.system(.body, design: .monospaced))
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 8)
                                .allowsHitTesting(false)
                        }
                    }
                    .accessibilityLabel("Proxy URLs to import")

                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .center, spacing: 16) {
                        importFootnote
                        Spacer(minLength: 8)
                        importButton
                    }
                    .frame(minWidth: 440)

                    VStack(alignment: .leading, spacing: 10) {
                        importFootnote
                        HStack {
                            Spacer()
                            importButton
                        }
                    }
                }
            }
        } label: {
            Label("Import Proxies", systemImage: "square.and.arrow.down")
        }
    }

    private var importFootnote: some View {
        Text("One URL per line. Credentials are masked in the list and stored locally.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var importButton: some View {
        Button("Import Proxies", systemImage: "square.and.arrow.down") {
            model.importProxies(importText)
            importText = ""
        }
        .buttonStyle(.borderedProminent)
        .disabled(importText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    private func proxyRow(_ proxy: ProxyEntry) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                proxyToggle(proxy)
                    .frame(minWidth: 130, maxWidth: 170, alignment: .leading)

                proxyDetails(proxy)
                    .frame(maxWidth: .infinity, alignment: .leading)

                proxyManualAction(proxy)
                removeProxyButton(proxy)
            }
            .frame(minWidth: 440)

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    proxyToggle(proxy)
                    Spacer(minLength: 8)
                    removeProxyButton(proxy)
                }

                proxyDetails(proxy)

                HStack {
                    Spacer(minLength: 8)
                    proxyManualAction(proxy)
                }
            }
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }

    private func proxyToggle(_ proxy: ProxyEntry) -> some View {
        Toggle(isOn: Binding(
            get: { proxy.enabled },
            set: { model.setProxyEnabled(proxy.id, enabled: $0) }
        )) {
            Text(proxy.label)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .toggleStyle(.checkbox)
    }

    private func proxyDetails(_ proxy: ProxyEntry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(maskedProxyURL(proxy.url))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            healthLabel(proxy.health)
        }
    }

    @ViewBuilder
    private func proxyManualAction(_ proxy: ProxyEntry) -> some View {
        if model.proxyState.mode == .manual && model.proxyState.manualId == proxy.id {
            Label("Selected", systemImage: "checkmark.circle.fill")
                .font(.callout)
                .foregroundStyle(.green)
                .fixedSize()
        } else {
            Button("Set Manual") {
                model.chooseManualProxy(proxy.id)
            }
            .buttonStyle(.borderless)
            .disabled(!proxy.enabled)
            .help("Use this proxy in Manual mode")
        }
    }

    private func removeProxyButton(_ proxy: ProxyEntry) -> some View {
        Button(role: .destructive) {
            model.removeProxy(proxy.id)
        } label: {
            Image(systemName: "trash")
                .frame(width: 28, height: 28)
        }
        .buttonStyle(.borderless)
        .disabled(model.checkingProxies)
        .help("Remove proxy")
        .accessibilityLabel("Remove \(proxy.label)")
    }

    @ViewBuilder
    private func healthLabel(_ health: ProxyHealth?) -> some View {
        if let health {
            Label(
                health.ok
                    ? "Passed · \(health.latencyMs.map { "\(Int($0)) ms" } ?? "")"
                    : "Failed · \(health.error ?? "unavailable")",
                systemImage: health.ok ? "checkmark.circle" : "xmark.circle"
            )
            .font(.caption)
            .foregroundStyle(health.ok ? .green : .red)
            .lineLimit(1)
            .truncationMode(.middle)
            .help(health.error ?? "")
        } else {
            Label("Not tested", systemImage: "questionmark.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var modeDescription: String {
        switch model.proxyState.mode {
        case .off:
            "OpenCode connects directly. Proxy variables inherited from the shell are ignored."
        case .manual:
            "OpenCode uses only the selected, enabled proxy. If it is unavailable, the server will not start."
        case .auto:
            "RelayDock chooses an enabled proxy and keeps an account-specific binding. No eligible proxy means no direct fallback."
        }
    }

    private var modeSymbol: String {
        model.proxyState.mode == .off ? "arrow.up.right" : "lock.shield"
    }
}
