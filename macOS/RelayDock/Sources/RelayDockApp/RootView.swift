import RelayDockCore
import SwiftUI

/// The main window: a native source list on the left and one settings page on
/// the right. Navigation lives in the sidebar; actions live in the toolbar.
struct RootView: View {
    @ObservedObject var model: ProxyAppModel
    /// The updater is its own observable; the model does not republish on it.
    @ObservedObject private var updates: UpdateModel
    /// Fixtures open the advanced disclosure without a click.
    var showsAdvanced = false

    @State private var isImportPresented = false

    init(model: ProxyAppModel, showsAdvanced: Bool = false) {
        _model = ObservedObject(wrappedValue: model)
        _updates = ObservedObject(wrappedValue: model.updates)
        self.showsAdvanced = showsAdvanced
    }

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .frame(minWidth: 680, minHeight: 500)
        .task {
            if model.state == nil && model.loadError == nil {
                model.load()
            }
            model.routingSetup.refresh()
            await model.pollEdgeStatusWhileVisible()
        }
        .task {
            await model.updates.autoCheckIfDue()
        }
        .sheet(isPresented: $isImportPresented) {
            ProxyImportSheet(model: model)
        }
        .sheet(isPresented: $model.isManualChooserPresented, onDismiss: {
            model.cancelRoutingChanges(from: .manualChooser)
        }) {
            ManualProxyChooser(model: model)
        }
        .modifier(RoutingModeWarningPresenter(model: model, source: .window))
        .onDisappear { model.cancelRoutingChanges(from: .window) }
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

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            List(selection: sidebarSelection) {
                Section("RelayDock") {
                    ForEach(ProxyAppTab.allCases) { tab in
                        Label(tab.title, systemImage: tab.symbol)
                            .tag(tab)
                    }
                }
            }
            .listStyle(.sidebar)

            Divider()
            SidebarFooter(edgeStatus: model.edgeStatus, updates: updates)
        }
        .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
    }

    private var sidebarSelection: Binding<ProxyAppTab?> {
        Binding(
            get: { model.selectedTab },
            set: { tab in
                if let tab { model.selectedTab = tab }
            }
        )
    }
}

/// The sidebar's Edge and version line. It observes Edge status directly so a
/// poll redraws this footer instead of the whole window — including the split
/// view that is mid-animation whenever the sidebar is expanding or collapsing.
private struct SidebarFooter: View {
    @ObservedObject var edgeStatus: EdgePanelModel
    @ObservedObject var updates: UpdateModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: edgeSymbol)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(edgeText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
            }
            .help(edgeHelp)

            Text(updates.versionDisplayText)
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var edgeSymbol: String {
        switch edgeStatus.panel {
        case .running: "bolt.horizontal.circle"
        case .notRunning: "bolt.slash"
        case .notConfigured: "questionmark.circle"
        case .unknown: "circle.dotted"
        }
    }

    private var edgeText: String {
        switch edgeStatus.panel {
        case .running(let status):
            "Edge · \(status.counters.tunnelsActive) active"
        case .notRunning:
            "Edge not running"
        case .notConfigured:
            "Edge not set up"
        case .unknown:
            "Edge · checking"
        }
    }

    private var edgeHelp: String {
        switch edgeStatus.panel {
        case .running(let status):
            "RelayDock Edge is running with \(status.counters.tunnelsActive) active tunnels."
        case .notRunning:
            "RelayDock Edge is not running; it starts on demand."
        case .notConfigured:
            "RelayDock Edge is not installed. Open Routing to set it up."
        case .unknown:
            "RelayDock Edge status is not known yet."
        }
    }
}

private extension RootView {

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        Group {
            if model.state != nil {
                switch model.selectedTab {
                case .routing:
                    RoutingView(model: model, showsAdvanced: showsAdvanced)
                case .pool:
                    ProxyPoolView(model: model) {
                        isImportPresented = true
                    }
                }
            } else if let loadError = model.loadError {
                ContentUnavailableView {
                    Label("Proxy Configuration Unavailable", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(loadError)
                } actions: {
                    Button("Try Again") { model.reload() }
                        .buttonStyle(.borderedProminent)
                }
            } else {
                ProgressView("Loading proxy configuration…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if let banner = updateBanner {
                HStack(alignment: .center, spacing: 12) {
                    Image(systemName: banner.symbol)
                        .font(.title3)
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(banner.title)
                            .font(.callout.weight(.medium))
                        if let detail = banner.detail {
                            Text(detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 12)
                    UpdateFooterView(
                        updates: updates,
                        showsWhenIdle: false,
                        showsVersion: false,
                        showsPhaseDescription: false
                    )
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(.bar)
                .overlay(alignment: .bottom) { Divider() }
            }
        }
        .navigationTitle(model.selectedTab.title)
        .toolbar { toolbar }
    }

    /// The window only surfaces updates that need attention; the quiet daily
    /// check and its "up to date" result stay out of the way.
    private var updateBanner: UpdateBanner? {
        switch updates.phase {
        case .idle, .checking, .upToDate:
            nil
        case .available(let release):
            UpdateBanner(
                symbol: "arrow.down.circle",
                title: "Version \(release.version) is available",
                detail: "You’re running \(updates.versionDisplayText)."
            )
        case .downloading(let release):
            UpdateBanner(
                symbol: "arrow.down.circle",
                title: "Downloading version \(release.version)",
                detail: nil
            )
        case .ready(let release):
            UpdateBanner(
                symbol: "checkmark.circle",
                title: "Version \(release.version) is ready",
                detail: "Restart RelayDock to finish installing."
            )
        case .failed(let message):
            UpdateBanner(
                symbol: "exclamationmark.triangle",
                title: "Update failed",
                detail: message
            )
        }
    }

    private struct UpdateBanner {
        let symbol: String
        let title: String
        let detail: String?
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                Task { await model.testAll() }
            } label: {
                if model.isTesting {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Testing proxies")
                } else {
                    Label("Test All", systemImage: "arrow.clockwise")
                }
            }
            .disabled(model.isTesting || model.state?.enabledProxies.isEmpty != false)
            .help("Test every enabled proxy")

            Button {
                isImportPresented = true
            } label: {
                Label("Import Proxies", systemImage: "plus")
            }
            .keyboardShortcut("o", modifiers: [.command, .shift])
            .disabled(model.state == nil)
            .help("Import proxy URLs")
        }
    }
}

private struct ManualProxyChooser: View {
    @ObservedObject var model: ProxyAppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Choose a Proxy")
                    .font(.title2.weight(.semibold))
                Text("Manual mode requires an enabled proxy with a valid URL.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(.bottom, 14)

            List(model.manualCandidates) { proxy in
                Button {
                    Task { await model.selectManualProxy(proxy.id, source: .manualChooser) }
                } label: {
                    HStack(spacing: 10) {
                        ProxyHealthIcon(proxy: proxy)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(proxy.label)
                                .font(.body)
                                .foregroundStyle(.primary)
                            if proxyLabel(for: proxy.url) != proxy.label {
                                Text(proxyLabel(for: proxy.url))
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(model.isCheckingOpenCodeRouting || model.pendingRoutingChange != nil)
            }
            .listStyle(.inset)

            HStack {
                Spacer()
                Button("Cancel") {
                    model.cancelRoutingChanges(from: .manualChooser)
                    model.isManualChooserPresented = false
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
            .padding(.top, 12)
        }
        .padding(20)
        .frame(width: 460, height: 380)
        .modifier(RoutingModeWarningPresenter(model: model, source: .manualChooser))
    }
}
