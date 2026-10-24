import AppKit
import RelayDockCore
import SwiftUI

struct ProxyPoolView: View {
    @ObservedObject var model: ProxyAppModel
    var onImport: () -> Void

    @State private var expandedID: String?
    @State private var removalTarget: ProxyEntry?
    @State private var editTarget: ProxyEntry?

    /// `initiallyExpandedID` exists for fixtures, which need one row open
    /// without a click; the app always starts collapsed.
    init(
        model: ProxyAppModel,
        initiallyExpandedID: String? = nil,
        onImport: @escaping () -> Void
    ) {
        self.model = model
        self.onImport = onImport
        _expandedID = State(initialValue: initiallyExpandedID)
    }

    var body: some View {
        VStack(spacing: 0) {
            checkNotes
            poolContent
        }
        .navigationTitle("Proxy Pool")
        .sheet(item: $editTarget) { entry in
            ProxyImportSheet(model: model, editing: entry)
        }
        .confirmationDialog(
            "Remove \(removalTarget?.label ?? "proxy")?",
            isPresented: Binding(
                get: { removalTarget != nil },
                set: { if !$0 { removalTarget = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Remove Proxy", role: .destructive) {
                if let removalTarget { model.removeProxy(removalTarget.id) }
                removalTarget = nil
            }
            Button("Cancel", role: .cancel) { removalTarget = nil }
        } message: {
            Text("This also clears any saved manual or sticky references to this proxy.")
        }
    }

    // MARK: - Check notes

    @ViewBuilder
    private var checkNotes: some View {
        if model.lastCheckRoute != nil || model.checkNotice != nil {
            VStack(alignment: .leading, spacing: 4) {
                if let route = model.lastCheckRoute {
                    Label(
                        route == .edge
                            ? "Last check ran through RelayDock Edge."
                            : "RelayDock Edge was unreachable, so the last check ran in this app.",
                        systemImage: route == .edge ? "bolt.horizontal.circle" : "info.circle"
                    )
                }
                if let notice = model.checkNotice {
                    Label(notice, systemImage: "info.circle")
                        .help("A skipped check still has nothing to probe; it is not a failure.")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
            .background(Color(nsColor: .windowBackgroundColor))
            .overlay(alignment: .bottom) { Divider() }
        }
    }

    // MARK: - Body

    @ViewBuilder
    private var poolContent: some View {
        if let state = model.state, state.proxies.isEmpty {
            ContentUnavailableView {
                Label("No Proxies", systemImage: "network")
            } description: {
                Text("Import proxy URLs to build your pool.")
            } actions: {
                Button("Import Proxies…", action: onImport)
                    .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let proxies = model.state?.proxies {
            List {
                Section {
                    ForEach(proxies) { proxy in
                        ProxyPoolRow(
                            proxy: proxy,
                            model: model,
                            expandedID: $expandedID,
                            removalTarget: $removalTarget,
                            editTarget: $editTarget
                        )
                    }
                } header: {
                    HStack(spacing: 8) {
                        Text("Proxies")
                        Spacer(minLength: 8)
                        Text(summary(proxies))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textCase(nil)
                            .lineLimit(1)
                    }
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(footerSummary(proxies))
                        Text(AppCopy.verificationHonesty)
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .listStyle(.inset)
        }
    }

    private func summary(_ proxies: [ProxyEntry]) -> String {
        let enabled = proxies.filter(\.enabled)
        let healthy = enabled.filter { $0.health?.ok == true }.count
        let noun = proxies.count == 1 ? "proxy" : "proxies"
        guard !enabled.isEmpty else { return "\(proxies.count) \(noun) · none enabled" }
        return "\(proxies.count) \(noun) · \(healthy) of \(enabled.count) healthy"
    }

    /// The list's quiet summary: health counts plus the Auto eligibility rule.
    private func footerSummary(_ proxies: [ProxyEntry]) -> String {
        let enabled = proxies.filter(\.enabled)
        let healthy = enabled.filter { $0.health?.ok == true }.count
        let untested = enabled.filter { $0.health == nil }.count
        let failed = enabled.filter { $0.health?.ok == false }.count
        let disabled = proxies.count - enabled.count

        var parts = ["\(healthy) healthy"]
        if untested > 0 { parts.append("\(untested) untested") }
        if failed > 0 { parts.append("\(failed) failed") }
        if disabled > 0 { parts.append("\(disabled) disabled") }
        parts.append("Unchecked stays eligible for Auto")
        return parts.joined(separator: " · ")
    }
}

private struct ProxyPoolRow: View {
    let proxy: ProxyEntry
    @ObservedObject var model: ProxyAppModel
    @Binding var expandedID: String?
    @Binding var removalTarget: ProxyEntry?
    @Binding var editTarget: ProxyEntry?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isExpanded: Bool { expandedID == proxy.id }
    private var currentProxy: ProxyEntry {
        model.state?.proxies.first(where: { $0.id == proxy.id }) ?? proxy
    }
    private var isManual: Bool {
        model.state?.mode == .manual && model.state?.manualId == proxy.id
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Button {
                    toggleExpanded()
                } label: {
                    HStack(spacing: 10) {
                        ProxyHealthIcon(proxy: currentProxy)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(proxy.label)
                                .font(.body)
                                .foregroundStyle(proxy.enabled ? .primary : .secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)

                            Text(endpointLine)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint("Shows proxy details")

                Spacer(minLength: 8)

                ProxyStatusText(
                    proxy: currentProxy,
                    mode: model.state?.mode ?? .off,
                    isTesting: model.isTesting,
                    showsAge: true,
                    font: .caption
                )
                .frame(minWidth: 100, alignment: .trailing)

                Toggle(
                    "Enabled",
                    isOn: Binding(
                        get: { currentProxy.enabled },
                        set: { model.setEnabled(proxy.id, enabled: $0) }
                    )
                )
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .accessibilityLabel("Enable \(proxy.label)")

                Button {
                    toggleExpanded()
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .frame(width: 18, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isExpanded ? "Collapse \(proxy.label)" : "Expand \(proxy.label)")
            }
            .padding(.vertical, 3)

            if isExpanded {
                details
                    .transition(.opacity)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var endpointLine: String {
        if proxy.isCustomScript {
            return "Custom script · resolves at launch"
        }
        return proxyLabel(for: proxy.url)
    }

    // MARK: - Details

    private var details: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()

            HStack(spacing: 28) {
                detailPair("Protocol", proxy.isCustomScript ? "Custom (JS)" : proxyScheme)
                detailPair("Last test", healthDetail)
            }

            HStack(spacing: 16) {
                if isManual {
                    Label("Selected for Manual", systemImage: "checkmark.circle")
                        .foregroundStyle(.secondary)
                } else if currentProxy.enabled, currentProxy.hasValidDefinition {
                    Button("Use as Manual") {
                        Task { await model.selectManualProxy(proxy.id) }
                    }
                    .appAction(.link, size: .small)
                    .disabled(model.isCheckingOpenCodeRouting || model.pendingRoutingChange != nil)
                }

                if proxy.isCustomScript {
                    Button("Edit Script…") {
                        editTarget = proxy
                    }
                    .appAction(.link, size: .small)
                }

                if let script = proxy.script {
                    Button("Copy Script") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(script, forType: .string)
                    }
                    .appAction(.link, size: .small)
                } else {
                    Button("Copy Masked URL") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(maskedProxyURL(proxy.url), forType: .string)
                    }
                    .appAction(.link, size: .small)
                }

                Spacer(minLength: 8)

                Button {
                    removalTarget = proxy
                } label: {
                    Text("Remove")
                }
                .appAction(.link, size: .small)
            }

            if isManual, !currentProxy.enabled {
                Label(
                    "This Manual selection is disabled; routing will fail closed.",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.caption)
                .foregroundStyle(.primary)
            }
        }
        .font(.caption)
        .padding(.bottom, 10)
        .padding(.leading, 34)
    }

    private func detailPair(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .foregroundStyle(.secondary)
            Text(value)
                .lineLimit(1)
        }
    }

    private func toggleExpanded() {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
            expandedID = isExpanded ? nil : proxy.id
        }
    }

    // MARK: - Values

    private var proxyScheme: String {
        URLComponents(string: proxy.url)?.scheme?.uppercased() ?? "Unknown"
    }

    private var healthDetail: String {
        guard let health = currentProxy.health else { return "Not tested" }
        let result = health.ok ? ProxyStatus.healthSummary(for: currentProxy) : "Failed · \(health.error ?? "check failed")"
        guard health.checkedAt > 1_000_000_000_000 else { return result }
        let date = Date(timeIntervalSince1970: health.checkedAt / 1_000)
        let relative = RelativeDateTimeFormatter().localizedString(for: date, relativeTo: Date())
        return "\(result) · \(relative)"
    }
}
