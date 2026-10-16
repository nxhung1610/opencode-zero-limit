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
            Text("Live OpenCode traffic is not verified by this app.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
        }
        .frame(width: 360)
        .task {
            if model.state == nil && model.loadError == nil {
                model.load()
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("RelayDock")
                .font(.headline)
            Spacer(minLength: 8)
            if let state = model.state {
                Text("\(state.mode.rawValue.capitalized) · saved")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    @ViewBuilder
    private var content: some View {
        if let state = model.state {
            VStack(alignment: .leading, spacing: 12) {
                Picker("Proxy Mode", selection: modeSelection) {
                    Text("Off").tag(ProxyMode.off.rawValue)
                    Text("Manual").tag(ProxyMode.manual.rawValue)
                    Text("Auto").tag(ProxyMode.auto.rawValue)
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                statusLine(state)

                if let message = model.errorMessage {
                    errorBanner(message)
                }

                if state.proxies.isEmpty {
                    emptyPool
                } else {
                    proxyList(state)
                }
            }
            .padding(14)
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
                .controlSize(.small)
            }
            .padding(14)
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
                if model.isTesting {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Testing…")
                    }
                } else {
                    Text("Test All")
                }
            }
            .disabled(model.isTesting || model.state?.enabledProxies.isEmpty != false)
            .frame(maxWidth: .infinity)

            Button("Open RelayDock…") {
                presentWindow()
            }
            .buttonStyle(.borderedProminent)
            .frame(maxWidth: .infinity)
        }
        .controlSize(.small)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var modeSelection: Binding<String> {
        Binding(
            get: { model.state?.mode.rawValue ?? ProxyMode.off.rawValue },
            set: { rawValue in
                guard let mode = ProxyMode(rawValue: rawValue) else { return }
                model.selectMode(mode)
                if model.isManualChooserPresented {
                    presentWindow()
                }
            }
        )
    }

    @ViewBuilder
    private func statusLine(_ state: ProxyState) -> some View {
        switch state.mode {
        case .off:
            Text("Direct — no proxy")
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
        case .manual:
            if let label = validManualLabel(state) {
                Text("Manual · \(label)")
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
            } else {
                warningLabel("Manual selection missing or invalid. Routing fails closed; no direct fallback.")
            }
        case .auto:
            if state.enabledProxies.isEmpty {
                warningLabel("Enable a proxy before a consumer can use Auto mode.")
            } else if state.validEnabledProxies.isEmpty {
                warningLabel("No enabled proxy has a valid supported URL.")
            } else if state.autoEligibleProxies.isEmpty {
                warningLabel("All enabled proxies have a failed last check. Auto will fail closed.")
            } else {
                Text("\(state.autoEligibleProxies.count) eligible · \(state.enabledProxies.count) enabled")
                    .font(.callout.weight(.medium))
            }
        }
    }

    private func validManualLabel(_ state: ProxyState) -> String? {
        guard let id = state.manualId,
              let proxy = state.validEnabledProxies.first(where: { $0.id == id }) else { return nil }
        return proxy.label
    }

    private func warningLabel(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.triangle")
            .font(.footnote)
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
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
            .controlSize(.small)
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
            .controlSize(.small)
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
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                .padding(.top, 8)
            }
        }
    }

    private func proxyRow(_ proxy: ProxyEntry, mode: ProxyMode) -> some View {
        HStack(spacing: 8) {
            healthSymbol(proxy)
            Text(proxy.label)
                .font(.callout.weight(.medium))
                .foregroundStyle(proxy.enabled ? .primary : .secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            Text(ProxyStatus.text(for: proxy, mode: mode, isTesting: model.isTesting))
                .font(.footnote)
                .monospacedDigit()
                .foregroundStyle(ProxyStatus.color(for: proxy, isTesting: model.isTesting))
                .lineLimit(1)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 4)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func healthSymbol(_ proxy: ProxyEntry) -> some View {
        if !proxy.enabled {
            Image(systemName: "circle")
                .foregroundStyle(.tertiary)
                .accessibilityLabel("Disabled")
        } else if let health = proxy.health {
            Image(systemName: health.ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(health.ok ? Color.green : Color.orange)
                .accessibilityLabel(health.ok ? "Last test passed" : "Last test failed")
        } else {
            Image(systemName: "questionmark.circle")
                .foregroundStyle(.secondary)
                .accessibilityLabel("Not tested")
        }
    }

    private func presentWindow(tab: ProxyAppTab? = nil) {
        if let tab {
            model.selectedTab = tab
        }
        openWindow(id: "main")
        NSApp.activate()
    }
}
