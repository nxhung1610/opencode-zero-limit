import RelayDockCore
import SwiftUI

struct RoutingView: View {
    @ObservedObject var model: ProxyAppModel

    var body: some View {
        if let state = model.state {
            Form {
                Section {
                    routingState(state)

                    Picker("Proxy Mode", selection: modeSelection) {
                        Text("Off").tag(ProxyMode.off.rawValue)
                        Text("Manual").tag(ProxyMode.manual.rawValue)
                        Text("Auto").tag(ProxyMode.auto.rawValue)
                    }
                    .pickerStyle(.segmented)
                    .controlSize(.large)

                    if state.mode == .manual {
                        manualProxyControl(state)
                    }
                }

                Section {
                    LabeledContent("Policy", value: "Saved locally")
                }

                Section {
                    EdgePanelView(model: model)
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

    // MARK: - Routing state

    /// Prominent statement of where routing stands: mode, pool numbers, and
    /// the consequence that matters — fail closed, never direct fallback.
    private func routingState(_ state: ProxyState) -> some View {
        let consequence = RoutingStatePresentation.consequence(for: state)
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: RoutingStatePresentation.symbol(for: state))
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(RoutingStatePresentation.tint(for: state))
                .frame(width: 28, height: 28)
                .offset(y: -5)

            VStack(alignment: .leading, spacing: 3) {
                Text(RoutingStatePresentation.headline(for: state))
                    .font(.title3.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Text(consequence.text)
                    .font(.callout)
                    .foregroundStyle(consequence.isWarning ? Color.orange : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Manual

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
                    Text(manualCandidateTitle(proxy))
                        .tag(proxy.id)
                }
            }
            .controlSize(.large)
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
                    Button {
                        model.isManualChooserPresented = true
                    } label: {
                        Text("Choose…")
                            .padding(.vertical, 6)
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

    /// The picker reads "host:port" once when the label already is that
    /// authority, and keeps "label · detail" for custom labels.
    private func manualCandidateTitle(_ proxy: ProxyEntry) -> String {
        guard !proxy.isCustomScript else { return proxy.label }
        let detail = proxyLabel(for: proxy.url)
        if detail == proxy.label { return proxy.label }
        if detail.hasPrefix(proxy.label), detail.dropFirst(proxy.label.count).hasPrefix(":") {
            return detail
        }
        return "\(proxy.label) · \(detail)"
    }
}
