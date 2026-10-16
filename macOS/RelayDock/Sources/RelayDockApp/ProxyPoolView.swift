import AppKit
import RelayDockCore
import SwiftUI

struct ProxyPoolView: View {
    @ObservedObject var model: ProxyAppModel
    @State private var expandedID: String?
    @State private var showImport = false
    @State private var removalTarget: ProxyEntry?

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Proxy Pool")
                        .font(.headline)
                    Text("\(model.state?.proxies.count ?? 0) proxies")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

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
                .disabled(model.isTesting || model.state?.enabledProxies.isEmpty != false)

                Button {
                    showImport = true
                } label: {
                    Label("Import", systemImage: "plus")
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])
            }
            .padding(.horizontal, 22)
            .padding(.top, 18)
            .padding(.bottom, 12)

            Divider()

            if let state = model.state, state.proxies.isEmpty {
                ContentUnavailableView {
                    Label("No proxies yet", systemImage: "network")
                } description: {
                    Text("Import proxy URLs to build your pool.")
                } actions: {
                    Button("Import Proxies") { showImport = true }
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
                                removalTarget: $removalTarget
                            )
                            Divider().padding(.leading, 22)
                        }
                    }
                    .padding(.horizontal, 18)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .sheet(isPresented: $showImport) {
            ProxyImportSheet(model: model)
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

    private var isExpanded: Bool { expandedID == proxy.id }
    private var currentProxy: ProxyEntry {
        model.state?.proxies.first(where: { $0.id == proxy.id }) ?? proxy
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Button {
                    expandedID = isExpanded ? nil : proxy.id
                } label: {
                    HStack(spacing: 10) {
                        healthSymbol
                        VStack(alignment: .leading, spacing: 3) {
                            Text(proxy.label)
                                .font(.body.weight(.medium))
                                .foregroundStyle(.primary)
                            Text(proxyLabel(for: proxy.url))
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

                Text(healthSummary)
                    .font(.caption)
                    .foregroundStyle(healthColor)
                    .lineLimit(1)

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
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(maskedProxyURL(proxy.url), forType: .string)
                    } label: {
                        Label("Copy Masked URL", systemImage: "doc.on.doc")
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
                .accessibilityLabel("Actions for \(proxy.label)")
            }
            .padding(.vertical, 10)

            if isExpanded {
                VStack(alignment: .leading, spacing: 10) {
                    Divider()
                    HStack(spacing: 24) {
                        LabeledContent("Protocol", value: proxyScheme)
                        LabeledContent("Last test", value: healthDetail)
                    }

                    if model.state?.mode == .manual, model.state?.manualId == proxy.id {
                        Label("Selected for Manual", systemImage: "checkmark.circle")
                            .foregroundStyle(.secondary)
                    } else if currentProxy.enabled, parseProxyImportLine(currentProxy.url) == currentProxy.url {
                        Button("Use as Manual") { model.selectManualProxy(proxy.id) }
                            .buttonStyle(.link)
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

    @ViewBuilder
    private var healthSymbol: some View {
        if let health = currentProxy.health {
            Image(systemName: health.ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(health.ok ? Color.green : Color.orange)
                .accessibilityLabel(health.ok ? "Last test passed" : "Last test failed")
        } else {
            Image(systemName: "questionmark.circle")
                .foregroundStyle(.secondary)
                .accessibilityLabel("Not tested")
        }
    }

    private var healthSummary: String {
        guard let health = currentProxy.health else { return "Not tested" }
        guard health.ok else { return "Failed" }
        if let latency = health.latencyMs { return "Passed · \(Int(latency.rounded())) ms" }
        return "Passed"
    }

    private var healthColor: Color {
        guard let health = currentProxy.health else { return .secondary }
        return health.ok ? .secondary : .orange
    }

    private var proxyScheme: String {
        URLComponents(string: proxy.url)?.scheme?.uppercased() ?? "Unknown"
    }

    private var healthDetail: String {
        guard let health = currentProxy.health else { return "Not tested" }
        let result = health.ok ? healthSummary : "Failed · \(health.error ?? "check failed")"
        guard health.checkedAt > 1_000_000_000_000 else { return result }
        let date = Date(timeIntervalSince1970: health.checkedAt / 1_000)
        let relative = RelativeDateTimeFormatter().localizedString(for: date, relativeTo: Date())
        return "\(result) · \(relative)"
    }
}

struct ProxyImportSheet: View {
    @ObservedObject var model: ProxyAppModel
    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @State private var validationError: String?

    /// `initialText` exists for offscreen fixtures; the app always opens the sheet empty.
    init(model: ProxyAppModel, initialText: String = "") {
        self.model = model
        _text = State(initialValue: initialText)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Import Proxies")
                .font(.title2.weight(.semibold))
            Text("Paste one URL per line. Supports HTTP, HTTPS, SOCKS5, and SOCKS5H.")
                .foregroundStyle(.secondary)

            ZStack(alignment: .topLeading) {
                TextEditor(text: $text)
                    .font(.system(.body, design: .monospaced))
                    .accessibilityLabel("Proxy URLs, one per line")
                if text.isEmpty {
                    // `verbatim` keeps the sample URLs plain — the default Text
                    // init auto-links them into a blue clickable style.
                    // `top` aligns the hint with where the editor draws real text.
                    Text(verbatim: "http://proxy.example:8080\nsocks5h://proxy.example:1080")
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 5)
                        .padding(.top, 1)
                        .allowsHitTesting(false)
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
            }

            if let validationError {
                Label(validationError, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Text("Cancel")
                        .padding(.vertical, 6)
                }
                .keyboardShortcut(.cancelAction)
                Button {
                    if let error = model.importProxies(text) {
                        validationError = error
                    } else {
                        dismiss()
                    }
                } label: {
                    Text("Import")
                        .padding(.vertical, 6)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 520, height: 370)
        .onChange(of: text) { _, _ in validationError = nil }
    }
}
