import RelayDockCore
import SwiftUI

struct RootView: View {
    @ObservedObject var model: ProxyAppModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                ForEach(ProxyAppTab.allCases) { tab in
                    tabButton(tab)
                }
            }
            .padding(.top, 12)
            .padding(.bottom, 10)

            Divider()

            Group {
                if model.state != nil {
                    if model.selectedTab == .routing {
                        RoutingView(model: model)
                    } else {
                        ProxyPoolView(model: model)
                    }
                } else if let loadError = model.loadError {
                    ContentUnavailableView {
                        Label("Proxy configuration unavailable", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(loadError)
                    } actions: {
                        Button("Try Again") { model.reload() }
                            .appAction(.secondary)
                    }
                } else {
                    ProgressView("Loading proxy configuration…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if model.state != nil {
                HonestyFootnote()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, AppLayout.windowGutter)
                    .padding(.vertical, 10)
            }
        }
        .frame(minWidth: 600, minHeight: 400)
        .task {
            if model.state == nil && model.loadError == nil {
                model.load()
            }
            await model.pollEdgeStatusWhileVisible()
        }
        .sheet(isPresented: $model.isManualChooserPresented) {
            ManualProxyChooser(model: model)
        }
        .alert(
            "Couldn’t update proxy settings",
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.clearError() } }
            )
        ) {
            Button("OK", role: .cancel) { model.clearError() }
        } message: {
            Text(model.errorMessage ?? "Unknown error")
        }
    }

    private func tabButton(_ tab: ProxyAppTab) -> some View {
        let isSelected = model.selectedTab == tab
        return Button {
            model.selectedTab = tab
        } label: {
            VStack(spacing: 5) {
                Image(systemName: tab.symbol)
                    .font(.system(size: 21, weight: .regular))
                Text(tab.title)
                    .font(.system(size: 13, weight: .medium))
            }
            .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
            .frame(width: 112, height: 64)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Color.accentColor.opacity(0.12))
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isSelected ? "\(tab.title), selected" : tab.title)
    }
}

private struct ManualProxyChooser: View {
    @ObservedObject var model: ProxyAppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            AppTitle(
                title: "Choose a proxy for Manual",
                subtitle: "Manual mode requires an enabled proxy with a valid URL.",
                style: .modal
            )

            List(model.manualCandidates) { proxy in
                Button {
                    model.selectManualProxy(proxy.id)
                    dismiss()
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(proxy.label)
                            .foregroundStyle(.primary)
                        if proxyLabel(for: proxy.url) != proxy.label {
                            Text(proxyLabel(for: proxy.url))
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .listStyle(.plain)

            HStack {
                Spacer()
                Button("Cancel") {
                    model.isManualChooserPresented = false
                    dismiss()
                }
                .appAction(.secondary, size: .large)
                .keyboardShortcut(.cancelAction)
            }
        }
        .padding(18)
        .frame(width: 420, height: 330)
    }
}
