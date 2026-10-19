import AppKit
import RelayDockCore
import SwiftUI

/// The menu bar glance surface: saved mode, pool health, and quick actions — no state of its own.
struct MenuBarPanelView: View {
    @ObservedObject var model: ProxyAppModel
    @Environment(\.openWindow) private var openWindow

    private static let maximumVisibleProxies = 6

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
            Divider()
            actions
            Divider()
            UpdateFooterView(updates: model.updates)
                .padding(.horizontal, AppLayout.panelGutter)
                .padding(.top, 10)
            HonestyFootnote()
                .padding(.horizontal, AppLayout.panelGutter)
                .padding(.vertical, 12)
        }
        .frame(width: 360)
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

    private var header: some View {
        AppTitle(title: "RelayDock")
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, AppLayout.panelGutter)
            .padding(.top, 12)
            .padding(.bottom, 12)
    }

    @ViewBuilder
    private var content: some View {
        if let state = model.state {
            VStack(alignment: .leading, spacing: 12) {
                ModeSegmentedPicker(mode: modeBinding)

                stateAnchor(state)

                switch model.edgePanel {
                case .running(let status):
                    edgeLine(running: status, savedMode: state.mode)
                case .notRunning:
                    Label("Edge not running", systemImage: "bolt.horizontal.circle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .help("RelayDock Edge starts on demand at the next wrapped launch.")
                case .unknown, .notConfigured:
                    EmptyView()
                }

                if let message = model.errorMessage {
                    errorBanner(message)
                }

                if state.proxies.isEmpty {
                    emptyPool
                } else {
                    proxyList(state)
                }
            }
            .padding(AppLayout.panelGutter)
        } else if let loadError = model.loadError {
            VStack(alignment: .leading, spacing: 10) {
                Label("Proxy configuration unavailable", systemImage: "exclamationmark.triangle")
                    .font(.callout.weight(.medium))
                Text(loadError)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Try Again") {
                    model.reload()
                }
                .appAction(.secondary, size: .large)
            }
            .padding(AppLayout.panelGutter)
        } else {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Loading proxy configuration…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(20)
        }
    }

    private var actions: some View {
        HStack(spacing: 10) {
            Button {
                Task { await model.testAll() }
            } label: {
                Group {
                    if model.isTesting {
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Testing…")
                        }
                    } else {
                        Label("Test All", systemImage: "arrow.clockwise")
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .appAction(.secondary, size: .large)
            .disabled(model.isTesting || model.state?.enabledProxies.isEmpty != false)

            Button {
                presentWindow()
            } label: {
                Label("Open RelayDock…", systemImage: "macwindow")
                    .frame(maxWidth: .infinity)
            }
            .appAction(.primary, size: .large)
        }
        .padding(.horizontal, AppLayout.panelGutter)
        .padding(.vertical, 12)
    }

    private var modeBinding: Binding<ProxyMode> {
        Binding(
            get: { model.state?.mode ?? .off },
            set: { mode in
                model.selectMode(mode)
                if model.isManualChooserPresented {
                    presentWindow()
                }
            }
        )
    }

    /// The glance's anchor: the same symbol, tint, headline, and — when it
    /// matters — consequence line the Routing tab shows, so a warning reads
    /// the same on both surfaces.
    private func stateAnchor(_ state: ProxyState) -> some View {
        let consequence = RoutingStatePresentation.consequence(for: state)
        return HStack(alignment: .top, spacing: 9) {
            Image(systemName: RoutingStatePresentation.symbol(for: state))
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(RoutingStatePresentation.tint(for: state))
                .frame(width: 18, alignment: .leading)

            VStack(alignment: .leading, spacing: 2) {
                Text(RoutingStatePresentation.headline(for: state))
                    .font(.callout.weight(.semibold))
                    .monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)
                if shouldShowConsequence(consequence, for: state) {
                    Text(consequence.text)
                        .font(.caption)
                        .foregroundStyle(consequence.isWarning ? Color.orange : Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// Warnings always get their line. Calm captions are shown only when they
    /// add something now: Manual's fail-closed promise, and Auto's
    /// "unchecked may be eligible" note while an enabled proxy is unchecked.
    private func shouldShowConsequence(
        _ consequence: RoutingStatePresentation.Consequence,
        for state: ProxyState
    ) -> Bool {
        if consequence.isWarning { return true }
        switch state.mode {
        case .off:
            return false
        case .manual:
            return true
        case .auto:
            return state.validEnabledProxies.contains { $0.health == nil }
        }
    }

    /// Edge's own accounting: mode only when it diverges from the saved one,
    /// then the upstream in use and how many tunnels are live.
    private func edgeLine(running status: EdgeStatusResponse, savedMode: ProxyMode) -> some View {
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

        return HStack(spacing: 5) {
            Image(systemName: "bolt.horizontal.circle")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.green)
                .accessibilityLabel("RelayDock Edge")
            Text(parts.joined(separator: " · "))
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .help("From Edge's own tunnel accounting.")
    }

    private func errorBanner(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.footnote)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            Button("Dismiss") {
                model.clearError()
            }
            .appAction(.link, size: .small)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var emptyPool: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("No proxies yet")
                .font(.callout.weight(.semibold))
            Text("Import proxy URLs to build your pool.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Add Proxies…") {
                presentWindow(tab: .pool)
            }
            .appAction(.secondary, size: .large)
        }
    }

    private func proxyList(_ state: ProxyState) -> some View {
        let visible = Array(state.proxies.prefix(Self.maximumVisibleProxies))
        return VStack(spacing: 0) {
            ForEach(visible) { proxy in
                proxyRow(proxy, mode: state.mode)
                if proxy.id != visible.last?.id {
                    Divider()
                        .padding(.leading, 27)
                }
            }
            if state.proxies.count > Self.maximumVisibleProxies {
                Button {
                    presentWindow(tab: .pool)
                } label: {
                    Text("\(state.proxies.count - Self.maximumVisibleProxies) more…")
                        .font(.footnote)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .appAction(.link, size: .small)
                .padding(.top, 8)
            }
        }
    }

    private func proxyRow(_ proxy: ProxyEntry, mode: ProxyMode) -> some View {
        HStack(spacing: 8) {
            ProxyHealthIcon(proxy: proxy)
            Text(proxy.label)
                .font(.callout.weight(.medium))
                .foregroundStyle(proxy.enabled ? .primary : .secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            ProxyStatusText(proxy: proxy, mode: mode, isTesting: model.isTesting)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(rowAccessibilityLabel(proxy, mode: mode))
        .help(ProxyStatus.detail(for: proxy))
    }

    /// Row age suffix; hidden while a test run is rewriting results.
    private func rowAge(_ proxy: ProxyEntry) -> String? {
        guard !model.isTesting, proxy.enabled else { return nil }
        return ProxyStatus.checkedAgo(for: proxy)
    }

    private func rowAccessibilityLabel(_ proxy: ProxyEntry, mode: ProxyMode) -> String {
        var parts = [proxy.label, ProxyStatus.text(for: proxy, mode: mode, isTesting: model.isTesting)]
        if proxy.enabled, let health = proxy.health, !health.ok, let error = health.error {
            parts.append(error)
        }
        if let age = rowAge(proxy) {
            parts.append("checked \(age)")
        }
        return parts.joined(separator: ", ")
    }

    private func presentWindow(tab: ProxyAppTab? = nil) {
        if let tab {
            model.selectedTab = tab
        }
        openWindow(id: "main")
        NSApp.activate()
    }
}
