import RelayDockCore
import SwiftUI

struct RoutingView: View {
    @ObservedObject var model: ProxyAppModel
    @State private var showsAdvanced: Bool

    init(model: ProxyAppModel, showsAdvanced: Bool = false) {
        self.model = model
        _showsAdvanced = State(initialValue: showsAdvanced)
    }

    var body: some View {
        Form {
            if let state = model.state {
                overview(state)
                routingNotice
                policy(state)
                advanced
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Routing")
    }

    // MARK: - Overview

    private func overview(_ state: ProxyState) -> some View {
        let enabled = state.enabledProxies.count
        let healthy = state.enabledProxies.filter { $0.health?.ok == true }.count
        let eligibleValue = enabled == 0 ? "0" : "\(state.autoEligibleProxies.count)/\(enabled)"
        let healthyValue = enabled == 0 ? "0" : "\(healthy)/\(enabled)"

        return Section {
            LabeledContent("Status") {
                statusLabel(for: state)
            }
            LabeledContent("Enabled") {
                Text("\(enabled)").monospacedDigit()
            }
            LabeledContent("Auto eligible") {
                Text(eligibleValue).monospacedDigit()
            }
            LabeledContent("Healthy") {
                Text(healthyValue).monospacedDigit()
            }
        } header: {
            Text("Overview")
        } footer: {
            Text("How RelayDock Edge routes OpenCode traffic.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func statusLabel(for state: ProxyState) -> some View {
        let consequence = RoutingStatePresentation.consequence(for: state)

        if consequence.isWarning {
            Label("\(modeName(state.mode)) · attention", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.primary)
        } else {
            Label(modeName(state.mode), systemImage: statusSymbol(for: state.mode))
                .foregroundStyle(.secondary)
        }
    }

    private func statusSymbol(for mode: ProxyMode) -> String {
        switch mode {
        case .off: "circle"
        case .manual, .auto: "checkmark.circle.fill"
        }
    }

    private func modeName(_ mode: ProxyMode) -> String {
        switch mode {
        case .off: "Off"
        case .manual: "Manual"
        case .auto: "Auto"
        }
    }

    // MARK: - OpenCode notice

    @ViewBuilder
    private var routingNotice: some View {
        if model.isCheckingOpenCodeRouting || model.hasOpenCodeRoutingNotice {
            Section {
                OpenCodeRoutingNotice(model: model)
            }
        }
    }

    // MARK: - Policy

    private func policy(_ state: ProxyState) -> some View {
        let consequence = RoutingStatePresentation.consequence(for: state)
        let isBusy = model.isCheckingOpenCodeRouting || model.pendingRoutingChange != nil

        return Section {
            LabeledContent("Mode") {
                Picker("Mode", selection: modeBinding) {
                    ForEach(ProxyMode.allCases) { mode in
                        Text(modeName(mode)).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 280)
                .disabled(isBusy)
            }

            Text(Self.modeGuidance)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if consequence.isWarning {
                Label(consequence.text, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if state.mode == .manual {
                manualSection(state)
            }

            Toggle("Direct fallback", isOn: directFallbackBinding)
            Text("If no proxy is usable, connect directly (unverified) instead of failing closed.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } header: {
            Text("Policy")
        } footer: {
            Text(AppCopy.verificationHonesty)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private static let modeGuidance = """
    Off saves an explicit direct policy. Manual routes through one chosen proxy and fails closed unless direct fallback is on. Auto picks among enabled proxies whose last check did not fail.
    """

    private var modeBinding: Binding<ProxyMode> {
        Binding(
            get: { model.state?.mode ?? .off },
            set: { mode in Task { await model.selectMode(mode) } }
        )
    }

    private var directFallbackBinding: Binding<Bool> {
        Binding(
            get: { model.state?.directFallback ?? false },
            set: { model.setDirectFallback($0) }
        )
    }

    // MARK: - Manual

    @ViewBuilder
    private func manualSection(_ state: ProxyState) -> some View {
        LabeledContent("Manual proxy") {
            manualControl(state)
        }

        if let selected = state.proxies.first(where: { $0.id == state.manualId }),
           let health = selected.health, !health.ok {
            Label(
                state.directFallback
                    ? "Last test failed. Manual remains configured; Edge falls back to a direct connection."
                    : "Last test failed. Manual remains configured; Edge fails closed.",
                systemImage: "exclamationmark.triangle"
            )
            .font(.callout)
            .foregroundStyle(.primary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func manualControl(_ state: ProxyState) -> some View {
        let isBusy = model.isCheckingOpenCodeRouting || model.pendingRoutingChange != nil

        if let manualID = state.manualId,
           state.validEnabledProxies.contains(where: { $0.id == manualID }) {
            Picker(
                "Manual proxy",
                selection: Binding(
                    get: { model.state?.manualId ?? manualID },
                    set: { id in Task { await model.selectManualProxy(id) } }
                )
            ) {
                ForEach(model.manualCandidates) { proxy in
                    Text(manualCandidateTitle(proxy)).tag(proxy.id)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(maxWidth: 240)
            .disabled(isBusy)
        } else {
            HStack(spacing: 8) {
                if state.manualId != nil {
                    Label("Selected proxy needs attention", systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.primary)
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

    // MARK: - Advanced

    private var advanced: some View {
        Section {
            DisclosureGroup(isExpanded: $showsAdvanced) {
                VStack(alignment: .leading, spacing: 18) {
                    RoutingSetupView(model: model.routingSetup)
                    Divider()
                    EdgePanelView(model: model)
                }
                .padding(.vertical, 6)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Label("RelayDock Edge & routing setup", systemImage: "bolt.horizontal.circle")
                        if needsAttention {
                            Image(systemName: "exclamationmark.circle.fill")
                                .foregroundStyle(.primary)
                                .accessibilityLabel("Needs attention")
                        }
                    }
                    Text(advancedSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
        }
    }

    private var advancedSummary: String {
        var parts: [String] = []

        switch model.edgePanel {
        case .running(let status):
            parts.append(status.counters.tunnelsActive > 0
                ? "Edge running · \(status.counters.tunnelsActive) active"
                : "Edge running")
        case .notRunning:
            parts.append("Edge not running")
        case .notConfigured:
            parts.append("Edge not installed")
        case .unknown:
            parts.append("Edge status unknown")
        }

        switch model.routingSetup.state {
        case .installed(let installation):
            if installation.componentsOutOfDate {
                parts.append("setup needs update")
            } else if !installation.agentPlistInstalled {
                parts.append("agent missing")
            } else {
                parts.append("setup installed")
            }
        case .notInstalled:
            parts.append("setup not installed")
        case .checking, .unavailable:
            break
        }

        return parts.joined(separator: " · ")
    }

    private var needsAttention: Bool {
        if case .installed(let installation) = model.routingSetup.state {
            if installation.componentsOutOfDate || !installation.agentPlistInstalled {
                return true
            }
        }
        if case .notConfigured = model.edgePanel {
            return true
        }
        return false
    }
}
