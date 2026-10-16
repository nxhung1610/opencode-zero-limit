import RelayDockCore
import SwiftUI

struct RoutingView: View {
    @ObservedObject var model: ProxyAppModel

    var body: some View {
        if let state = model.state {
            Form {
                Section {
                    Picker("Proxy Mode", selection: modeSelection) {
                        Text("Off").tag(ProxyMode.off.rawValue)
                        Text("Manual").tag(ProxyMode.manual.rawValue)
                        Text("Auto").tag(ProxyMode.auto.rawValue)
                    }
                    .pickerStyle(.segmented)

                    if state.mode == .manual {
                        manualProxyControl(state)
                    }

                    if state.mode == .auto {
                        autoPoolSummary(state)
                    }
                }

                Section {
                    LabeledContent("Policy", value: "Saved locally")
                    if state.mode == .off {
                        Text("Off saves an explicit direct-routing policy. This app does not apply it to OpenCode.")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.top, 16)
        }
    }

    private var modeSelection: Binding<String> {
        Binding(
            get: { model.state?.mode.rawValue ?? ProxyMode.off.rawValue },
            set: { rawValue in
                guard let mode = ProxyMode(rawValue: rawValue) else { return }
                model.selectMode(mode)
            }
        )
    }

    @ViewBuilder
    private func manualProxyControl(_ state: ProxyState) -> some View {
        if let manualID = state.manualId,
           state.validEnabledProxies.contains(where: { $0.id == manualID }) {
            Picker(
                "Manual Proxy",
                selection: Binding(
                    get: { model.state?.manualId ?? manualID },
                    set: { model.selectManualProxy($0) }
                )
            ) {
                ForEach(model.manualCandidates) { proxy in
                    Text("\(proxy.label) · \(proxyLabel(for: proxy.url))")
                        .tag(proxy.id)
                }
            }
        } else {
            LabeledContent("Manual Proxy") {
                HStack(spacing: 10) {
                    if state.manualId != nil {
                        Label("Selected proxy needs attention", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    } else {
                        Text("Choose an enabled proxy")
                            .foregroundStyle(.secondary)
                    }
                    Button("Choose…") {
                        model.isManualChooserPresented = true
                    }
                    .disabled(model.manualCandidates.isEmpty)
                }
            }
        }

        if let selected = state.proxies.first(where: { $0.id == state.manualId }),
           let health = selected.health, !health.ok {
            LabeledContent("Last test") {
                Text("Failed — Manual remains configured; no direct fallback.")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func autoPoolSummary(_ state: ProxyState) -> some View {
        LabeledContent("Auto Pool") {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(state.autoEligibleProxies.count) eligible · \(state.enabledProxies.count) enabled")
                if state.enabledProxies.isEmpty {
                    Text("Enable a proxy before a consumer can use Auto mode.")
                        .foregroundStyle(.orange)
                } else if state.validEnabledProxies.isEmpty {
                    Text("No enabled proxy has a valid supported URL.")
                        .foregroundStyle(.orange)
                } else if state.autoEligibleProxies.isEmpty {
                    Text("All enabled proxies have a failed last check. Auto will fail closed.")
                        .foregroundStyle(.orange)
                } else {
                    Text("Unchecked proxies may be eligible.")
                        .foregroundStyle(.secondary)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}
