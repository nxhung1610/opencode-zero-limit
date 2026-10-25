import Combine
import CryptoKit
import Foundation
import RelayDockCore

/// The Routing page's setup section: whether the PATH wrapper is installed,
/// whether its components still match this build's bundled pair, and the
/// actions that change it. The app never edits shell profiles — the PATH
/// snippet is copyable text, and the only shell the section runs is the
/// user-clicked Verify.
@MainActor
final class RoutingSetupModel: ObservableObject {
    enum State: Equatable {
        case checking
        /// This build carries no bundled components (package/test runs).
        case unavailable
        case notInstalled
        case installed(Installation)
    }

    struct Installation: Equatable {
        /// The launchd agent plist exists.
        var agentPlistInstalled: Bool
        /// The installed binaries differ from this build's bundled pair — the
        /// card offers Update Components so app and daemon speak one version.
        var componentsOutOfDate: Bool
    }

    /// What a login shell resolves `opencode` to — the only honest PATH
    /// answer, because a GUI app's own PATH is the launchd one.
    enum PathCheck: Equatable {
        case unchecked
        case ok
        case notFound
        case shadowed(String)
    }

    enum Activity: Equatable {
        case idle
        case installing
        case uninstalling
        case verifying
    }

    struct ProcessResult: Equatable, Sendable {
        var status: Int32
        var stdout: String
        var stderr: String
    }

    typealias ProcessRunner = @Sendable (URL, [String], [String: String]) async -> ProcessResult

    @Published private(set) var state: State = .checking
    @Published private(set) var pathCheck: PathCheck = .unchecked
    @Published private(set) var activity: Activity = .idle
    @Published private(set) var errorMessage: String?
    @Published var isUninstallPresented = false

    private let storeDirectory: URL
    private let bundledEdgeURL: URL?
    private let bundledLauncherURL: URL?
    private let bundledFreeUsagePluginURL: URL?
    private let environment: [String: String]
    private let runProcess: ProcessRunner

    init(
        storeDirectory: URL,
        bundledResources: URL? = Bundle.main.resourceURL,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        runProcess: @escaping ProcessRunner = RoutingSetupModel.runProcess
    ) {
        self.storeDirectory = storeDirectory
        self.bundledEdgeURL = bundledResources?.appending(path: "relaydock-edge")
        self.bundledLauncherURL = bundledResources?.appending(path: "relaydock-launch")
        self.bundledFreeUsagePluginURL = bundledResources?.appending(path: "relaydock-free-usage-limit.js")
        self.environment = environment
        self.runProcess = runProcess
    }

    // MARK: - Paths

    private var home: URL {
        if let value = environment["HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !value.isEmpty {
            return URL(fileURLWithPath: value, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    private var installedEdgeURL: URL {
        home.appending(path: ".local/bin", directoryHint: .isDirectory).appending(path: "relaydock-edge")
    }

    private var installedLauncherURL: URL {
        home.appending(path: ".local/bin", directoryHint: .isDirectory).appending(path: "relaydock-launch")
    }

    private var commandLinkURL: URL {
        home.appending(path: ".local/bin", directoryHint: .isDirectory).appending(path: "opencode")
    }

    private var installedFreeUsagePluginURL: URL {
        if let custom = environment["OPENCODE_CONFIG_DIR"], !custom.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return URL(fileURLWithPath: custom, isDirectory: true)
                .appending(path: "plugins", directoryHint: .isDirectory)
                .appending(path: "relaydock-free-usage-limit.js")
        }
        let configRoot: URL
        if let xdg = environment["XDG_CONFIG_HOME"], !xdg.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            configRoot = URL(fileURLWithPath: xdg, isDirectory: true)
        } else {
            configRoot = home.appending(path: ".config", directoryHint: .isDirectory)
        }
        return configRoot.appending(path: "opencode/plugins/relaydock-free-usage-limit.js")
    }

    private var agentPlistURL: URL {
        EdgeLaunchAgent.plistURL(environment: environment)
    }

    /// The child environment for install/uninstall. The launcher resolves
    /// `edge.json` at launch from the default directory unless
    /// `RELAYDOCK_CONFIG_DIR` is set, so a store that lives elsewhere (dev
    /// runs) must ride along — otherwise the install would serve a config
    /// real terminals never read.
    private var childEnvironment: [String: String] {
        var child = environment
        let defaultDirectory = EdgeConfigFile.configDirectory(environment: environment)
        if storeDirectory.standardizedFileURL != defaultDirectory.standardizedFileURL {
            child["RELAYDOCK_CONFIG_DIR"] = storeDirectory.path
        }
        return child
    }

    // MARK: - State

    /// Cheap file checks; safe to call on every window open.
    func refresh() {
        guard let edge = bundledEdgeURL, let launcher = bundledLauncherURL,
              FileManager.default.isExecutableFile(atPath: edge.path),
              FileManager.default.isExecutableFile(atPath: launcher.path) else {
            state = .unavailable
            return
        }
        let manager = FileManager.default
        guard manager.isExecutableFile(atPath: installedEdgeURL.path) else {
            state = .notInstalled
            pathCheck = .unchecked
            return
        }
        state = .installed(Installation(
            agentPlistInstalled: manager.fileExists(atPath: agentPlistURL.path),
            componentsOutOfDate: !Self.filesMatch(edge, installedEdgeURL)
                || !Self.filesMatch(launcher, installedLauncherURL)
                || Self.freeUsagePluginNeedsUpdate(
                    bundled: bundledFreeUsagePluginURL,
                    installed: installedFreeUsagePluginURL
                )
        ))
    }

    // MARK: - Actions

    /// Installs or updates: the bundled `relaydock-edge install` copies both
    /// binaries, links `opencode`, keeps-or-writes `edge.json`, writes and
    /// bootstraps the launchd agent, and waits for Edge to answer.
    func install() async {
        guard activity == .idle else { return }
        guard let edge = bundledEdgeURL, let launcher = bundledLauncherURL else {
            errorMessage = "This build has no bundled routing components."
            return
        }
        activity = .installing
        errorMessage = nil
        let result = await runProcess(
            edge, ["install", "--launcher", launcher.path], childEnvironment
        )
        refresh()
        activity = .idle
        if result.status == 0 {
            await verifyPath()
        } else {
            errorMessage = Self.failureMessage(
                result, fallback: "Installing the routing components failed."
            )
        }
    }

    func uninstall() async {
        guard activity == .idle, let edge = bundledEdgeURL else { return }
        activity = .uninstalling
        errorMessage = nil
        let result = await runProcess(edge, ["uninstall"], childEnvironment)
        refresh()
        activity = .idle
        if result.status != 0 {
            errorMessage = Self.failureMessage(
                result, fallback: "Removing the routing components failed."
            )
        }
    }

    /// Runs the user's login shell (`zsh -lic 'command -v opencode'`) so the
    /// answer reflects their real PATH, never the app's launchd environment.
    func verifyPath() async {
        guard activity == .idle else { return }
        activity = .verifying
        defer { activity = .idle }
        let result = await runProcess(
            URL(fileURLWithPath: "/bin/zsh"), ["-lic", "command -v opencode"], environment
        )
        let resolved = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.status != 0 || resolved.isEmpty {
            pathCheck = .notFound
        } else if URL(fileURLWithPath: resolved).standardizedFileURL == commandLinkURL.standardizedFileURL {
            pathCheck = .ok
        } else {
            pathCheck = .shadowed(resolved)
        }
    }

    /// Seeds the card without touching the disk (fixtures and tests).
    func applyForFixtures(state: State, pathCheck: PathCheck = .ok) {
        self.state = state
        self.pathCheck = pathCheck
    }

    // MARK: - Helpers

    private static func filesMatch(_ lhs: URL, _ rhs: URL) -> Bool {
        guard let left = try? Data(contentsOf: lhs, options: .mappedIfSafe),
              let right = try? Data(contentsOf: rhs, options: .mappedIfSafe) else { return false }
        if left.count != right.count { return false }
        return SHA256.hash(data: left) == SHA256.hash(data: right)
    }

    /// The app bundle carries the plugin beside its Edge binary. Only compare
    /// files RelayDock owns; a same-named unrelated OpenCode plugin remains
    /// untouched and must not leave Setup permanently showing Update.
    private static func freeUsagePluginNeedsUpdate(bundled: URL?, installed: URL) -> Bool {
        let marker = "// RelayDock-managed plugin."
        guard let bundled,
              let bundledText = try? String(contentsOf: bundled, encoding: .utf8),
              bundledText.contains(marker) else { return false }
        guard let installedText = try? String(contentsOf: installed, encoding: .utf8) else { return true }
        guard installedText.contains(marker) else { return false }
        return !filesMatch(bundled, installed)
    }

    private static func failureMessage(_ result: ProcessResult, fallback: String) -> String {
        let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !detail.isEmpty else { return fallback }
        // The installer writes one message per line; the last is the reason.
        return detail.split(separator: "\n").last.map(String.init) ?? fallback
    }

    /// `Process` off the main thread with the caller's environment; both
    /// streams are captured so failures can speak for themselves. Internal
    /// (not private) so it can be a default argument value, and `nonisolated`
    /// so that default is a plain `@Sendable` function value.
    nonisolated static func runProcess(
        _ executable: URL,
        _ arguments: [String],
        _ environment: [String: String]
    ) async -> ProcessResult {
        await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            process.environment = environment
            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr
            do {
                try process.run()
            } catch {
                return ProcessResult(status: 127, stdout: "", stderr: error.localizedDescription)
            }
            let outData = stdout.fileHandleForReading.readDataToEndOfFile()
            let errData = stderr.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return ProcessResult(
                status: process.terminationStatus,
                stdout: String(decoding: outData, as: UTF8.self),
                stderr: String(decoding: errData, as: UTF8.self)
            )
        }.value
    }
}
