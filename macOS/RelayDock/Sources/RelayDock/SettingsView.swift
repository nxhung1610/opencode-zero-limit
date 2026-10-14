import RelayDockCore
import SwiftUI

struct SettingsView: View {
    @Bindable var model: AppModel
    @State private var binaryPath = ""
    @State private var legacyWrapperManager = LegacyWrapperManager()
    @State private var legacyWrapperStatus: LegacyWrapperStatus = .absent
    @State private var confirmingLegacyWrapperRemoval = false
    @State private var legacyWrapperExpanded = false
    @State private var legacyWrapperMessage: String?
    @State private var legacyWrapperError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PageHeader(
                title: "Settings",
                subtitle: "Configure how RelayDock starts and connects to OpenCode."
            ) {
                EmptyView()
            }

            Form {
                Section {
                    Toggle("Start the managed OpenCode server when RelayDock opens", isOn: setting(\.autoStart))
                    Toggle("Rotate accounts automatically after quota events", isOn: setting(\.autoRotate))
                } header: {
                    Text("Automation")
                } footer: {
                    Text("Account rotation only applies to supported OpenCode quota events and saved accounts.")
                }

                Section {
                    TextField("Binary path", text: $binaryPath, prompt: Text("Resolve OpenCode from PATH"))
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(saveBinaryPath)
                        .disabled(model.serverBusy)

                    HStack {
                        Text("Leave blank to use the installed OpenCode binary.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Save Path") { saveBinaryPath() }
                            .disabled(model.serverBusy || binaryPath == (model.settings.opencodeBin ?? ""))
                    }
                } header: {
                    Text("OpenCode CLI")
                }

                Section {
                    Picker("Appearance", selection: setting(\.theme)) {
                        Text("System").tag("system")
                        Text("Light").tag("light")
                        Text("Dark").tag("dark")
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("Appearance")
                }

                Section {
                    LabeledContent("Settings file") {
                        Text(SettingsStore().fileURL.path)
                            .font(.system(.caption, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                            .frame(maxWidth: 420, alignment: .trailing)
                    }
                } header: {
                    Text("Local Data")
                } footer: {
                    Text("RelayDock reuses the existing local settings and proxy configuration.")
                }

                Section {
                    DisclosureGroup("Legacy Terminal Wrapper", isExpanded: $legacyWrapperExpanded) {
                        VStack(alignment: .leading, spacing: 12) {
                            legacyWrapperStatusView

                            Text("This removes only the old RelayDock symlink at ~/.local/bin/opencode. The installed OpenCode binary and unrelated files are never changed.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)

                            if let legacyWrapperMessage {
                                Label(legacyWrapperMessage, systemImage: "checkmark.circle.fill")
                                    .font(.callout)
                                    .foregroundStyle(.green)
                            }
                            if let legacyWrapperError {
                                Label(legacyWrapperError, systemImage: "exclamationmark.triangle.fill")
                                    .font(.callout)
                                    .foregroundStyle(.red)
                            }

                            HStack(spacing: 8) {
                                Button("Refresh", systemImage: "arrow.clockwise") {
                                    legacyWrapperStatus = legacyWrapperManager.status()
                                    legacyWrapperMessage = nil
                                    legacyWrapperError = nil
                                }
                                .buttonStyle(.bordered)

                                Button("Remove Wrapper", systemImage: "trash", role: .destructive) {
                                    confirmingLegacyWrapperRemoval = true
                                }
                                .buttonStyle(.bordered)
                                .disabled(!hasManagedLegacyWrapper)
                            }
                        }
                        .padding(.top, 8)
                    }
                } header: {
                    Text("Migration")
                }
            }
            .formStyle(.grouped)
        }
        .frame(maxWidth: 800, alignment: .leading)
        .padding(.horizontal, 24)
        .padding(.top, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear {
            binaryPath = model.settings.opencodeBin ?? ""
            legacyWrapperStatus = legacyWrapperManager.status()
        }
        .onChange(of: model.settings.opencodeBin) { _, value in binaryPath = value ?? "" }
        .confirmationDialog(
            "Remove the old RelayDock OpenCode wrapper?",
            isPresented: $confirmingLegacyWrapperRemoval,
            titleVisibility: .visible
        ) {
            Button("Remove Wrapper", role: .destructive, action: removeLegacyWrapper)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Only the symlink at \(legacyWrapperManager.wrapperURL.path) will be removed if it points to RelayDock’s old wrapper. The real OpenCode binary and all other files will be left untouched.")
        }
    }

    @ViewBuilder
    private var legacyWrapperStatusView: some View {
        switch legacyWrapperStatus {
        case .absent:
            Label("No old RelayDock wrapper found.", systemImage: "checkmark.circle")
                .foregroundStyle(.secondary)
        case .managed(let target):
            VStack(alignment: .leading, spacing: 4) {
                Label("Old RelayDock wrapper detected", systemImage: "exclamationmark.triangle")
                Text(target)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .foregroundStyle(.secondary)
            }
        case .unrelated:
            Label(
                "\(legacyWrapperManager.wrapperURL.path) is not managed by RelayDock and will not be changed.",
                systemImage: "lock.shield"
            )
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func setting<Value>(_ keyPath: WritableKeyPath<AppSettings, Value>) -> Binding<Value> {
        Binding(
            get: { model.settings[keyPath: keyPath] },
            set: { value in model.updateSettings { $0[keyPath: keyPath] = value } }
        )
    }

    private func saveBinaryPath() {
        let trimmed = binaryPath.trimmingCharacters(in: .whitespacesAndNewlines)
        model.updateSettings { $0.opencodeBin = trimmed.isEmpty ? nil : trimmed }
    }

    private var hasManagedLegacyWrapper: Bool {
        if case .managed = legacyWrapperStatus { return true }
        return false
    }

    private func removeLegacyWrapper() {
        do {
            legacyWrapperStatus = try legacyWrapperManager.remove()
            legacyWrapperMessage = "Removed the old RelayDock wrapper symlink."
            legacyWrapperError = nil
        } catch {
            legacyWrapperError = error.localizedDescription
            legacyWrapperMessage = nil
            legacyWrapperStatus = legacyWrapperManager.status()
        }
    }
}
