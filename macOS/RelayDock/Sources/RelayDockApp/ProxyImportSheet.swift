import RelayDockCore
import SwiftUI

enum ProxyImportMode: String, CaseIterable, Identifiable {
    case single
    case bulk

    var id: String { rawValue }

    var title: String {
        switch self {
        case .single: "Add One"
        case .bulk: "Bulk Import"
        }
    }
}

enum ProxyInputScheme: String, CaseIterable, Identifiable {
    case http
    case https
    case socks4
    case socks4a
    case socks5
    case socks5h
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .http: "HTTP"
        case .https: "HTTPS"
        case .socks4: "SOCKS4"
        case .socks4a: "SOCKS4A"
        case .socks5: "SOCKS5"
        case .socks5h: "SOCKS5H"
        case .custom: "Custom (JS)"
        }
    }

    var isCustom: Bool { self == .custom }
}

private enum ScriptTestState: Equatable {
    case idle
    case running
    case resolved(String)
    case failed(String)
}

struct ProxyImportSheet: View {
    @ObservedObject var model: ProxyAppModel
    @Environment(\.dismiss) private var dismiss
    @State private var mode: ProxyImportMode
    @State private var text: String
    @State private var scheme: ProxyInputScheme
    @State private var host = ""
    @State private var port = ""
    @State private var username = ""
    @State private var password = ""
    @State private var scriptName = ""
    @State private var script: String
    @State private var scriptTest: ScriptTestState = .idle
    @State private var validationError: String?

    /// The initial values exist for offscreen fixtures; the app always opens the
    /// sheet empty in Add One mode.
    init(
        model: ProxyAppModel,
        initialText: String = "",
        initialMode: ProxyImportMode = .single,
        initialScheme: ProxyInputScheme = .http,
        initialScript: String = ""
    ) {
        self.model = model
        _mode = State(initialValue: initialMode)
        _text = State(initialValue: initialText)
        _scheme = State(initialValue: initialScheme)
        _script = State(initialValue: initialScript)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            Picker("Input Mode", selection: $mode) {
                ForEach(ProxyImportMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Group {
                if mode == .single {
                    singleForm
                } else {
                    bulkForm
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            if let validationError {
                Label(validationError, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            footer
        }
        .padding(20)
        .frame(width: 520, height: 440)
        .onChange(of: mode) { validationError = nil; scriptTest = .idle }
        .onChange(of: text) { validationError = nil }
        .onChange(of: scheme) { validationError = nil; scriptTest = .idle }
        .onChange(of: script) { scriptTest = .idle }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Add Proxies")
                .font(.title2.weight(.semibold))
            Text(mode == .single
                 ? "Add one proxy by type, or write a custom script."
                 : "Paste one URL per line. Supports HTTP, HTTPS, SOCKS4, SOCKS4A, SOCKS5, and SOCKS5H.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Add One

    @ViewBuilder
    private var singleForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    fieldLabel("Type")
                        .gridColumnAlignment(.trailing)
                    Picker("Type", selection: $scheme) {
                        ForEach(ProxyInputScheme.allCases) { scheme in
                            Text(scheme.title).tag(scheme)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 150)
                }

                if scheme.isCustom {
                    GridRow {
                        fieldLabel("Name")
                        TextField("e.g. Rotating pool", text: $scriptName)
                    }
                } else {
                    GridRow {
                        fieldLabel("Host")
                        TextField("proxy.example, 10.0.0.1, or 2001:db8::1", text: $host)
                    }
                    GridRow {
                        fieldLabel("Port")
                        TextField("1080", text: $port)
                            .frame(width: 80)
                    }
                    GridRow {
                        fieldLabel("Username")
                        TextField("Optional", text: $username)
                    }
                    GridRow {
                        fieldLabel("Password")
                        SecureField("Optional", text: $password)
                    }
                }
            }

            if scheme.isCustom {
                customScriptPanel
            } else {
                urlPreview
            }
        }
    }

    @ViewBuilder
    private var urlPreview: some View {
        if let assembled = assembledURL {
            HStack(spacing: 6) {
                Image(systemName: "arrow.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Text(maskedProxyURL(assembled))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .textSelection(.enabled)
            }
        } else if !host.isEmpty || !port.isEmpty {
            Text(host.contains("://")
                 ? "Paste a full URL in Bulk Import instead of the Host field."
                 : "Enter a host and a port (1–65535).")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private var customScriptPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topLeading) {
                TextEditor(text: $script)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 148)
                    .accessibilityLabel("Proxy script")
                if script.isEmpty {
                    // `verbatim` keeps the sample code plain — the default Text
                    // init auto-links URLs into a blue clickable style.
                    Text(verbatim: "// Runs when a consumer starts OpenCode.\n// Return a proxy URL or host:port.\nconst res = http.get(\"https://api.example.com/proxy\");\nreturn JSON.parse(res).url;")
                        .font(.system(.callout, design: .monospaced))
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

            Text("Available: http.get(url, headers?), btoa, atob, console. No file or process access. The script must return a value.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Button {
                    runScriptTest()
                } label: {
                    Text("Test Script")
                        .padding(.vertical, 4)
                }
                .disabled(script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || scriptTest == .running)
                scriptTestResult
            }
        }
    }

    @ViewBuilder
    private var scriptTestResult: some View {
        switch scriptTest {
        case .idle:
            EmptyView()
        case .running:
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("Running…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .resolved(let masked):
            Label("Resolves to \(masked)", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
                .lineLimit(1)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func runScriptTest() {
        let script = script
        scriptTest = .running
        Task.detached(priority: .userInitiated) {
            let outcome: ScriptTestState
            do {
                let url = try ProxyScriptRunner.resolve(script)
                outcome = .resolved(maskedProxyURL(url))
            } catch {
                outcome = .failed(error.localizedDescription)
            }
            await MainActor.run {
                // Ignore a stale result if the user edited the script while it ran.
                guard script == self.script else { return }
                scriptTest = outcome
            }
        }
    }

    // MARK: - Bulk Import

    private var bulkForm: some View {
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
    }

    // MARK: - Footer

    private var footer: some View {
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
                submit()
            } label: {
                Text(primaryButtonTitle)
                    .padding(.vertical, 6)
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!canSubmit)
        }
    }

    private var primaryButtonTitle: String {
        switch mode {
        case .single: scheme.isCustom ? "Add Script" : "Add"
        case .bulk: "Import"
        }
    }

    private var canSubmit: Bool {
        switch mode {
        case .bulk:
            return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .single:
            if scheme.isCustom {
                return !(scriptName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            return !(host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && port.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private func submit() {
        switch mode {
        case .bulk:
            if let error = model.importProxies(text) {
                validationError = error
            } else {
                dismiss()
            }
        case .single:
            if scheme.isCustom {
                if let error = model.addProxyScript(name: scriptName, script: script) {
                    validationError = error
                } else {
                    dismiss()
                }
            } else if let url = assembledURL {
                if let error = model.addProxyURL(url) {
                    validationError = error
                } else {
                    dismiss()
                }
            } else {
                validationError = host.contains("://")
                    ? "Paste a full URL in Bulk Import instead of the Host field."
                    : "Enter a host and a port (1–65535)."
            }
        }
    }

    // MARK: - Assembly

    private func fieldLabel(_ title: String) -> some View {
        Text(title)
            .foregroundStyle(.secondary)
            .frame(width: 64, alignment: .trailing)
    }

    /// Assembles and validates the typed fields with the same parser as bulk
    /// import lines; brackets IPv6 literals and percent-encodes credentials.
    private var assembledURL: String? {
        guard !scheme.isCustom else { return nil }
        let rawHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawPort = port.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawHost.isEmpty, !rawPort.isEmpty else { return nil }

        var hostPart = rawHost
        if hostPart.contains(":"), !hostPart.hasPrefix("[") {
            hostPart = "[\(hostPart)]"
        }
        var authority = hostPart
        let rawUser = username.trimmingCharacters(in: .whitespacesAndNewlines)
        if !rawUser.isEmpty {
            let encodedUser = rawUser.addingPercentEncoding(withAllowedCharacters: .urlUserAllowed) ?? rawUser
            if password.isEmpty {
                authority = "\(encodedUser)@\(authority)"
            } else {
                let encodedPassword = password.addingPercentEncoding(withAllowedCharacters: .urlPasswordAllowed) ?? password
                authority = "\(encodedUser):\(encodedPassword)@\(authority)"
            }
        }
        return parseProxyImportLine("\(scheme.rawValue)://\(authority):\(rawPort)")
    }
}
