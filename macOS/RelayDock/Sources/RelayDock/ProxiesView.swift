import RelayDockCore
import SwiftUI

struct ProxiesView: View {
    @Bindable var model: AppModel
    @State private var importText = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PageHeader(
                    title: "Proxies",
                    subtitle: "Choose how the managed OpenCode process connects to the network."
                ) {
                    EmptyView()
                }

                routingSection
                proxyPoolSection
                importSection

                Label(
                    "Manual and Auto fail closed. If a proxy cannot be selected, OpenCode will not fall back to a direct connection.",
                    systemImage: "lock.shield"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: 920, alignment: .leading)
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .top)
        }
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
                    LabeledContent("Selected proxy") {
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
                        .frame(maxWidth: 340, alignment: .trailing)
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

                HStack(alignment: .center, spacing: 16) {
                    Text("One URL per line. Credentials are masked in the list and stored locally.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Spacer(minLength: 8)

                    Button("Import Proxies", systemImage: "square.and.arrow.down") {
                        model.importProxies(importText)
                        importText = ""
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(importText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        } label: {
            Label("Import Proxies", systemImage: "square.and.arrow.down")
        }
    }

    private func proxyRow(_ proxy: ProxyEntry) -> some View {
        HStack(spacing: 12) {
            Toggle(proxy.label, isOn: Binding(
                get: { proxy.enabled },
                set: { model.setProxyEnabled(proxy.id, enabled: $0) }
            ))
            .toggleStyle(.checkbox)
            .frame(minWidth: 130, maxWidth: 190, alignment: .leading)

            VStack(alignment: .leading, spacing: 4) {
                Text(maskedProxyURL(proxy.url))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                healthLabel(proxy.health)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

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
        .padding(.vertical, 10)
        .contentShape(Rectangle())
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
            .help(health.error ?? "")
        } else {
            Label("Not tested", systemImage: "questionmark.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
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
