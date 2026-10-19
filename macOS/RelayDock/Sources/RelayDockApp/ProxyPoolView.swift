import AppKit
import RelayDockCore
import SwiftUI

struct ProxyPoolView: View {
    @ObservedObject var model: ProxyAppModel
    @State private var expandedID: String?
    @State private var showImport = false
    @State private var removalTarget: ProxyEntry?
    @State private var editTarget: ProxyEntry?

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center) {
                AppTitle(title: "Proxy Pool", subtitle: "\(model.state?.proxies.count ?? 0) proxies")

                Spacer()

                Button {
                    Task { await model.testAll() }
                } label: {
                    if model.isTesting {
                        HStack(spacing: 7) {
                            ProgressView().controlSize(.small)
                            Text("Testing…")
                        }
                    } else {
                        Label("Test All", systemImage: "arrow.clockwise")
                    }
                }
                .appAction(.secondary, size: .large)
                .disabled(model.isTesting || model.state?.enabledProxies.isEmpty != false)

                Button {
                    showImport = true
                } label: {
                    Label("Import", systemImage: "plus")
                }
                .appAction(.primary, size: .large)
                .keyboardShortcut("o", modifiers: [.command, .shift])
            }
            .padding(.horizontal, AppLayout.windowGutter)
            .padding(.top, 18)
            .padding(.bottom, 12)

            if let route = model.lastCheckRoute {
                Text(route == .edge
                     ? "Last check ran through RelayDock Edge."
                     : "RelayDock Edge was unreachable, so the last check ran in this app.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, AppLayout.windowGutter)
                    .padding(.bottom, 10)
            }

            if let notice = model.checkNotice {
                Label(notice, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, AppLayout.windowGutter)
                    .padding(.bottom, 10)
                    .help("A skipped check still has nothing to probe; it is not a failure.")
            }

            Divider()

            if let state = model.state, state.proxies.isEmpty {
                ContentUnavailableView {
                    Label("No proxies yet", systemImage: "network")
                } description: {
                    Text("Import proxy URLs to build your pool.")
                } actions: {
                    Button("Import Proxies") {
                        showImport = true
                    }
                    .appAction(.primary, size: .large)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let proxies = model.state?.proxies {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(proxies) { proxy in
                            ProxyPoolRow(
                                proxy: proxy,
                                model: model,
                                expandedID: $expandedID,
                                removalTarget: $removalTarget,
                                editTarget: $editTarget
                            )
                            if proxy.id != proxies.last?.id {
                                Divider().padding(.leading, 30)
                            }
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.bottom, 10)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .sheet(isPresented: $showImport) {
            ProxyImportSheet(model: model)
        }
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
}

private struct ProxyPoolRow: View {
    let proxy: ProxyEntry
    @ObservedObject var model: ProxyAppModel
    @Binding var expandedID: String?
    @Binding var removalTarget: ProxyEntry?
    @Binding var editTarget: ProxyEntry?

    private var isExpanded: Bool { expandedID == proxy.id }
    private var currentProxy: ProxyEntry {
        model.state?.proxies.first(where: { $0.id == proxy.id }) ?? proxy
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Button {
                    expandedID = isExpanded ? nil : proxy.id
                } label: {
                    HStack(spacing: 10) {
                        ProxyHealthIcon(proxy: currentProxy)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(proxy.label)
                                .font(.body.weight(.medium))
                                .foregroundStyle(.primary)
                            if proxy.isCustomScript {
                                Text("Custom script · resolves at launch")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            } else {
                                Text(proxyLabel(for: proxy.url))
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
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
                    showsAge: false,
                    font: .caption
                )
                .frame(minWidth: 96, alignment: .trailing)

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

                Menu {
                    if proxy.isCustomScript {
                        Button {
                            editTarget = proxy
                        } label: {
                            Label("Edit Script…", systemImage: "pencil")
                        }
                    }
                    if let script = proxy.script {
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(script, forType: .string)
                        } label: {
                            Label("Copy Script", systemImage: "doc.on.doc")
                        }
                    } else {
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(maskedProxyURL(proxy.url), forType: .string)
                        } label: {
                            Label("Copy Masked URL", systemImage: "doc.on.doc")
                        }
                    }
                    Button(role: .destructive) {
                        removalTarget = proxy
                    } label: {
                        Label("Remove Proxy", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: 24, height: 28)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("Actions for \(proxy.label)")

                Button {
                    expandedID = isExpanded ? nil : proxy.id
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .frame(width: 20, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isExpanded ? "Collapse \(proxy.label)" : "Expand \(proxy.label)")
            }
            .padding(.vertical, 8)

            if isExpanded {
                VStack(alignment: .leading, spacing: 10) {
                    Divider()
                    HStack(spacing: 24) {
                        LabeledContent("Protocol", value: proxy.isCustomScript ? "Custom (JS)" : proxyScheme)
                        LabeledContent("Last test", value: healthDetail)
                    }

                    if model.state?.mode == .manual, model.state?.manualId == proxy.id {
                        Label("Selected for Manual", systemImage: "checkmark.circle")
                            .foregroundStyle(.secondary)
                    } else if currentProxy.enabled, currentProxy.hasValidDefinition {
                        Button("Use as Manual") { model.selectManualProxy(proxy.id) }
                            .appAction(.link, size: .small)
                    }

                    if model.state?.mode == .manual,
                       model.state?.manualId == proxy.id,
                       !currentProxy.enabled {
                        Label("This Manual selection is disabled; routing will fail closed.", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                }
                .font(.caption)
                .padding(.leading, 30)
                .padding(.bottom, 12)
            }
        }
        .padding(.horizontal, 5)
        .background(isExpanded ? Color.primary.opacity(0.025) : Color.clear)
    }

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


