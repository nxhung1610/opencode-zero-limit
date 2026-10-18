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
        let consequence = stateConsequence(state)
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: stateSymbol(state))
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(stateTint(state))
                .frame(width: 28, height: 28)
                .offset(y: -5)

            VStack(alignment: .leading, spacing: 3) {
                Text(stateHeadline(state))
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

    private func stateSymbol(_ state: ProxyState) -> String {
        switch state.mode {
        case .off: return "arrow.right.circle"
        case .manual: return "hand.point.up.left"
        case .auto: return "wand.and.stars"
        }
    }

    private func stateTint(_ state: ProxyState) -> Color {
        switch state.mode {
        case .off:
            return .secondary
        case .manual:
            return validManual(state) != nil ? .accentColor : .orange
        case .auto:
            return state.autoEligibleProxies.isEmpty ? .orange : .green
        }
    }

    private func stateHeadline(_ state: ProxyState) -> String {
        switch state.mode {
        case .off:
            return "Direct — no proxy"
        case .manual:
            guard let proxy = validManual(state) else { return "Manual" }
            return "Manual · \(proxy.label)"
        case .auto:
            return "Auto · \(state.autoEligibleProxies.count) eligible · \(state.enabledProxies.count) enabled"
        }
    }

    private func stateConsequence(_ state: ProxyState) -> (text: String, isWarning: Bool) {
        switch state.mode {
        case .off:
            return ("Off saves an explicit direct-routing policy. This app does not apply it to OpenCode.", false)
        case .manual:
            guard validManual(state) != nil else {
                return ("Manual selection missing or invalid. Routing fails closed; no direct fallback.", true)
            }
            return ("If this proxy fails, routing fails closed — no direct fallback.", false)
        case .auto:
            if state.enabledProxies.isEmpty {
                return ("Enable a proxy before a consumer can use Auto mode.", true)
            } else if state.validEnabledProxies.isEmpty {
                return ("No enabled proxy has a valid supported URL.", true)
            } else if state.autoEligibleProxies.isEmpty {
                return ("All enabled proxies have a failed last check. Auto will fail closed.", true)
            }
            return ("Unchecked proxies may be eligible.", false)
        }
    }

    private func validManual(_ state: ProxyState) -> ProxyEntry? {
        guard let id = state.manualId else { return nil }
        return state.validEnabledProxies.first(where: { $0.id == id })
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
