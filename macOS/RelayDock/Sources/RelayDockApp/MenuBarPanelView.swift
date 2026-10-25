import AppKit
import RelayDockCore
import SwiftUI

/// The menu bar glance surface: saved mode, pool health, and quick actions — no state of its own.
struct MenuBarPanelView: View {
    @ObservedObject var model: ProxyAppModel
    @Environment(\.openWindow) private var openWindow

    private static let maximumVisibleProxies = 4

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            if let state = model.state {
                content(state)
                actions
                footer
            } else if let loadError = model.loadError {
                unavailable(loadError)
            } else {
                loading
            }
        }
        .padding(AppLayout.panelGutter)
        .frame(width: 360)
        .background(AppTheme.windowBackground)
        .modifier(RoutingModeWarningPresenter(model: model, source: .menu))
        .onDisappear { model.cancelRoutingChanges(from: .menu) }
        .task {
            if model.state == nil && model.loadError == nil {
                model.load()
            }
            await model.pollEdgeStatusWhileVisible()
        }
        .task {
            await model.updates.autoCheckIfDue()
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Text("RelayDock")
                .font(.headline)
            Spacer(minLength: 8)
            VerificationInfoButton(text: AppCopy.verificationHonesty)
        }
    }

    // MARK: - Content

    @ViewBuilder
    private func content(_ state: ProxyState) -> some View {
        statusSummary(state)

        Picker("Mode", selection: modeBinding) {
            ForEach(ProxyMode.allCases) { mode in
                Text(modeTitle(mode)).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .disabled(model.isCheckingOpenCodeRouting || model.pendingRoutingChange != nil)

        OpenCodeRoutingNotice(model: model, compact: true)

        edgeLine(state)

        if let message = model.errorMessage {
            errorBanner(message)
        }

        if state.proxies.isEmpty {
            emptyPool
        } else {
            proxyList(state)
        }
    }

    private func statusSummary(_ state: ProxyState) -> some View {
        let consequence = RoutingStatePresentation.consequence(for: state)
        let showsConsequence = state.mode != .off
            && RoutingStatePresentation.shouldShowConsequence(consequence, for: state)
        let isAlert = consequence.isWarning

        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: isAlert ? "exclamationmark.triangle.fill" : statusSymbol(state.mode))
                    .foregroundStyle(isAlert ? Color.primary : Color.secondary)
                Text(RoutingStatePresentation.headline(for: state))
                    .font(.headline)
                    .lineLimit(1)
            }
            if showsConsequence {
                Text(consequence.text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func statusSymbol(_ mode: ProxyMode) -> String {
        switch mode {
        case .off: "circle"
        case .manual, .auto: "checkmark.circle.fill"
        }
    }

    private func modeTitle(_ mode: ProxyMode) -> String {
        switch mode {
        case .off: "Off"
        case .manual: "Manual"
        case .auto: "Auto"
        }
    }

    /// Edge's own accounting: mode only when it diverges from the saved one,
    /// then the upstream in use and how many tunnels are live.
    @ViewBuilder
    private func edgeLine(_ state: ProxyState) -> some View {
        switch model.edgePanel {
        case .running(let status):
            HStack(spacing: 5) {
                Image(systemName: "bolt.horizontal.circle")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("RelayDock Edge")
                Text(edgeText(status, savedMode: state.mode))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .help("From Edge's own tunnel accounting.")
        case .notRunning:
            Label("Edge not running", systemImage: "bolt.slash")
                .font(.caption)
                .foregroundStyle(.secondary)
                .help("RelayDock Edge starts on demand at the next wrapped launch.")
        case .unknown, .notConfigured:
            EmptyView()
        }
    }

    private func edgeText(_ status: EdgeStatusResponse, savedMode: ProxyMode) -> String {
        var parts = ["Edge running"]
        if status.mode != savedMode {
            parts.append(status.mode.rawValue.capitalized)
        }
        if let upstream = status.upstream {
            parts.append(upstream.label)
        } else {
            parts.append(status.mode == .off ? "Direct" : "No upstream")
        }
        parts.append("\(status.counters.tunnelsActive) active")
        return parts.joined(separator: " · ")
    }

    // MARK: - Pool

    private func proxyList(_ state: ProxyState) -> some View {
        let visible = Array(state.proxies.prefix(Self.maximumVisibleProxies))
        return VStack(alignment: .leading, spacing: 2) {
            ForEach(visible) { proxy in
                proxyRow(proxy, mode: state.mode)
            }
            if state.proxies.count > Self.maximumVisibleProxies {
                Button {
                    presentWindow(tab: .pool)
                } label: {
                    Text("Manage all \(state.proxies.count) proxies…")
                        .font(.caption)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .appAction(.link, size: .small)
                .padding(.top, 4)
            }
        }
    }

    @ViewBuilder
    private func proxyRow(_ proxy: ProxyEntry, mode: ProxyMode) -> some View {
        if proxy.isFreeUsageLimited() {
            TimelineView(.periodic(from: .now, by: 1)) { timeline in
                proxyRowContent(proxy, mode: mode, now: timeline.date)
            }
        } else {
            proxyRowContent(proxy, mode: mode, now: Date())
        }
    }

    private func proxyRowContent(_ proxy: ProxyEntry, mode: ProxyMode, now: Date) -> some View {
        HStack(spacing: 8) {
            ProxyHealthIcon(proxy: proxy, now: now)
            Text(proxy.label)
                .font(.body)
                .foregroundStyle(proxy.enabled ? .primary : .secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            ProxyStatusText(
                proxy: proxy,
                mode: mode,
                isTesting: model.isTesting,
                probeStatus: model.freeUsageProbeStatuses[proxy.id],
                now: now,
                showsAge: true,
                font: .caption
            )
        }
        .frame(height: 22)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(rowAccessibilityLabel(proxy, mode: mode, now: now))
        .help(ProxyStatus.detail(for: proxy, now: now))
    }

    private func rowAccessibilityLabel(_ proxy: ProxyEntry, mode: ProxyMode, now: Date) -> String {
        var parts = [proxy.label, ProxyStatus.text(
            for: proxy,
            mode: mode,
            isTesting: model.isTesting && model.freeUsageProbeStatuses[proxy.id] == nil,
            probeStatus: model.freeUsageProbeStatuses[proxy.id],
            now: now
        )]
        if proxy.enabled, let health = proxy.health, !health.ok, let error = health.error {
            parts.append(error)
        }
        if let age = ProxyStatus.checkedAgo(for: proxy, now: now) {
            parts.append("checked \(age)")
        }
        return parts.joined(separator: ", ")
    }

    // MARK: - Actions

    private var actions: some View {
        VStack(spacing: 8) {
            Divider()

            HStack(spacing: 8) {
                Button {
                    Task { await model.testAll() }
                } label: {
                    Group {
                        if model.isTesting {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("Testing…")
                            }
                        } else {
                            Label("Test All", systemImage: "arrow.clockwise")
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(model.isTesting || model.state?.enabledProxies.isEmpty != false)

                Button {
                    presentWindow()
                } label: {
                    Label("Open RelayDock", systemImage: "macwindow")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Text(model.updates.versionDisplayText)
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.tertiary)

            Spacer(minLength: 8)

            UpdateFooterView(updates: model.updates, showsVersion: false)
        }
    }

    // MARK: - States

    private var emptyPool: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("No proxies yet")
                .font(.body.weight(.medium))
            Text("Import proxy URLs to build your pool.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Add Proxies…") {
                presentWindow(tab: .pool)
            }
            .buttonStyle(.bordered)
            .padding(.top, 2)
        }
    }

    private func errorBanner(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.caption.weight(.medium))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Dismiss") {
                model.clearError()
            }
            .appAction(.link, size: .small)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var loading: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text("Loading proxy configuration…")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
    }

    private func unavailable(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Proxy configuration unavailable", systemImage: "exclamationmark.triangle")
                .font(.body.weight(.medium))
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Try Again") {
                model.reload()
            }
            .buttonStyle(.bordered)
        }
    }

    // MARK: - Bindings

    private var modeBinding: Binding<ProxyMode> {
        Binding(
            get: { model.state?.mode ?? .off },
            set: { mode in
                Task {
                    await model.selectMode(mode, source: .menu)
                    if model.isManualChooserPresented { presentWindow() }
                }
            }
        )
    }

    private func presentWindow(tab: ProxyAppTab? = nil) {
        if let tab {
            model.selectedTab = tab
        }
        openWindow(id: "main")
        NSApp.activate()
    }
}
