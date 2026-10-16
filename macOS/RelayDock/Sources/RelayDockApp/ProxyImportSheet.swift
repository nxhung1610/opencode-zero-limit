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

    /// Initial values exist for offscreen fixtures; the app always opens the
    /// sheet empty in Add One mode.
    struct Prefill {
        var text = ""
        var mode = ProxyImportMode.single
        var scheme = ProxyInputScheme.http
        var host = ""
        var port = ""
        var username = ""
        var password = ""
        var script = ""
    }

    init(model: ProxyAppModel, prefill: Prefill = Prefill()) {
        self.model = model
        _mode = State(initialValue: prefill.mode)
        _text = State(initialValue: prefill.text)
        _scheme = State(initialValue: prefill.scheme)
        _host = State(initialValue: prefill.host)
        _port = State(initialValue: prefill.port)
        _username = State(initialValue: prefill.username)
        _password = State(initialValue: prefill.password)
        _script = State(initialValue: prefill.script)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 12)

            Picker("Input Mode", selection: $mode) {
                ForEach(ProxyImportMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 20)
            .padding(.bottom, 6)

            Form {
                if mode == .single {
                    singleForm
                } else {
                    bulkForm
                }
            }
            .formStyle(.grouped)

            if let validationError {
                Label(validationError, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 20)
                    .padding(.top, 6)
            }

            footer
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 16)
        }
        .frame(width: 520, height: 470)
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
        if scheme.isCustom {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        fieldLabel("Name")
                        TextField("Name", text: $scriptName, prompt: Text("e.g. Rotating pool"))
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                    }
                    scriptEditor
                    testScriptRow
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 2)
            } footer: {
                Text("Available: http.get(url, headers?), btoa, atob, console. No file or process access. The script must return a value.")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 10)
            }
        } else {
            Section {
                VStack(spacing: 10) {
                    HStack(spacing: 10) {
                        fieldLabel("Type")
                        Spacer(minLength: 10)
                        Picker("Type", selection: $scheme) {
                            ForEach(ProxyInputScheme.allCases) { scheme in
                                Text(scheme.title).tag(scheme)
                            }
                        }
                        .labelsHidden()
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    HStack(spacing: 10) {
                        fieldLabel("Host")
                        TextField("Host", text: $host, prompt: Text("proxy.example, 10.0.0.1, or 2001:db8::1"))
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                    }
                    HStack(spacing: 10) {
                        fieldLabel("Port")
                        TextField("Port", text: $port, prompt: Text("1080"))
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 84)
                        Spacer(minLength: 0)
                    }
                }
                .padding(.vertical, 2)
            } footer: {
                assembledPreview
            }

            Section {
                VStack(spacing: 10) {
                    HStack(spacing: 10) {
                        fieldLabel("Username")
                        TextField("Username", text: $username, prompt: Text("Optional"))
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                    }
                    HStack(spacing: 10) {
                        fieldLabel("Password")
                        SecureField("Password", text: $password, prompt: Text("Optional"))
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                    }
                }
                .padding(.vertical, 2)
            } header: {
                Text("Credentials")
            }
        }
    }

    private func fieldLabel(_ title: String) -> some View {
        Text(title)
            .frame(width: 78, alignment: .trailing)
    }

    /// The URL the typed fields currently assemble to, shown as the footer of
    /// the connection section — or a hint when the fields are incomplete.
    @ViewBuilder
    private var assembledPreview: some View {
        if let assembled = assembledURL {
            Text(maskedProxyURL(assembled))
                .font(.system(.caption, design: .monospaced))
                .lineLimit(1)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 10)
        } else if !host.isEmpty || !port.isEmpty {
            Text(host.contains("://")
                 ? "Paste a full URL in Bulk Import instead of the Host field."
                 : "Enter a host and a port (1–65535).")
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 10)
        }
    }

    private var scriptEditor: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $script)
                .font(.system(.body, design: .monospaced))
                .scrollContentBackground(.hidden)
                .frame(minHeight: 136)
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
    }

    private var testScriptRow: some View {
        HStack(spacing: 10) {
            Button {
                runScriptTest()
            } label: {
                Text("Test Script")
            }
            .disabled(script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || scriptTest == .running)
            scriptTestResult
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
        Section {
            ZStack(alignment: .topLeading) {
                TextEditor(text: $text)
                    .font(.system(.body, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 240)
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
