import Foundation
import RelayDockCore
import Testing

@testable import RelayDockApp

/// The Routing tab's setup card: reads its three shapes from a fake home
/// (not installed / installed in step / installed out of step), and runs the
/// bundled `relaydock-edge install|uninstall` through an injected runner so
/// nothing here touches the real `~/.local/bin`, launchd, or the network.
@MainActor
@Suite struct RoutingSetupTests {
    @Test func refreshReadsNotInstalled() throws {
        let fixture = try SetupFixture()
        defer { fixture.cleanUp() }

        let model = fixture.makeModel()
        model.refresh()

        #expect(model.state == .notInstalled)
        #expect(model.pathCheck == .unchecked)
    }

    @Test func refreshReadsInstalledWithMatchingComponents() throws {
        let fixture = try SetupFixture()
        defer { fixture.cleanUp() }
        try fixture.writeInstall(componentsMatchBundle: true, agentPlist: true)

        let model = fixture.makeModel()
        model.refresh()

        #expect(model.state == .installed(.init(agentPlistInstalled: true, componentsOutOfDate: false)))
    }

    @Test func refreshFlagsOutOfDateComponentsAndMissingAgent() throws {
        let fixture = try SetupFixture()
        defer { fixture.cleanUp() }
        try fixture.writeInstall(componentsMatchBundle: false, agentPlist: false)

        let model = fixture.makeModel()
        model.refresh()

        #expect(model.state == .installed(.init(agentPlistInstalled: false, componentsOutOfDate: true)))
    }

    @Test func refreshDetectsRelayDockPluginUpdatesWithoutClaimingUnrelatedPlugins() throws {
        let fixture = try SetupFixture()
        defer { fixture.cleanUp() }
        try fixture.writeInstall(componentsMatchBundle: true, agentPlist: false)
        let bundledPlugin = fixture.resourcesURL.appending(path: "relaydock-free-usage-limit.js")
        let pluginDirectory = fixture.home.appending(path: ".config/opencode/plugins", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: pluginDirectory, withIntermediateDirectories: true)
        let installedPlugin = pluginDirectory.appending(path: "relaydock-free-usage-limit.js")
        let current = "// RelayDock-managed plugin.\nexport const version = 'current';\n"
        try current.write(to: bundledPlugin, atomically: true, encoding: .utf8)
        try "// RelayDock-managed plugin.\nexport const version = 'old';\n"
            .write(to: installedPlugin, atomically: true, encoding: .utf8)
        let model = fixture.makeModel()

        model.refresh()
        #expect(model.state == .installed(.init(agentPlistInstalled: false, componentsOutOfDate: true)))

        try current.write(to: installedPlugin, atomically: true, encoding: .utf8)
        model.refresh()
        #expect(model.state == .installed(.init(agentPlistInstalled: false, componentsOutOfDate: false)))

        try "// An unrelated plugin with the same filename.\nexport const plugin = true;\n"
            .write(to: installedPlugin, atomically: true, encoding: .utf8)
        model.refresh()
        #expect(model.state == .installed(.init(agentPlistInstalled: false, componentsOutOfDate: false)))
    }

    @Test func refreshReportsUnavailableWithoutBundledComponents() throws {
        let fixture = try SetupFixture(includeBundledBinaries: false)
        defer { fixture.cleanUp() }

        let model = fixture.makeModel()
        model.refresh()

        #expect(model.state == .unavailable)
    }

    @Test func installRunsTheBundledInstallerAndVerifiesThePath() async throws {
        let fixture = try SetupFixture()
        defer { fixture.cleanUp() }
        let log = InvocationLog()
        let model = fixture.makeModel { executable, arguments, environment in
            log.record(executable: executable, arguments: arguments, environment: environment)
            if executable.lastPathComponent == "relaydock-edge" {
                try? fixture.writeInstall(componentsMatchBundle: true, agentPlist: true)
                return .init(status: 0, stdout: "Installed relaydock-launch, relaydock-edge, and the opencode symlink.\n", stderr: "")
            }
            return .init(status: 0, stdout: fixture.commandLinkURL.path + "\n", stderr: "")
        }

        await model.install()

        #expect(model.state == .installed(.init(agentPlistInstalled: true, componentsOutOfDate: false)))
        #expect(model.pathCheck == .ok)
        #expect(model.activity == .idle)
        #expect(model.errorMessage == nil)
        #expect(log.invocations.first?.executable == fixture.resourcesURL.appending(path: "relaydock-edge"))
        #expect(log.invocations.first?.arguments == [
            "install", "--launcher", fixture.resourcesURL.appending(path: "relaydock-launch").path,
        ])
        #expect(log.invocations.contains { $0.executable.path == "/bin/zsh" && $0.arguments == ["-lic", "command -v opencode"] })
    }

    @Test func installFailureSurfacesTheLastStderrLine() async throws {
        let fixture = try SetupFixture()
        defer { fixture.cleanUp() }
        let model = fixture.makeModel { _, _, _ in
            .init(
                status: 1,
                stdout: "",
                stderr: "relaydock-edge: could not create ~/.local/bin\n"
                    + "Refusing to replace /Users/x/.local/bin/opencode: it exists and is not a symlink.\n"
            )
        }

        await model.install()

        #expect(model.errorMessage == "Refusing to replace /Users/x/.local/bin/opencode: it exists and is not a symlink.")
        #expect(model.state == .notInstalled)
        #expect(model.activity == .idle)
    }

    @Test func uninstallRunsTheBundledUninstallerAndReturnsToNotInstalled() async throws {
        let fixture = try SetupFixture()
        defer { fixture.cleanUp() }
        try fixture.writeInstall(componentsMatchBundle: true, agentPlist: true)
        let log = InvocationLog()
        let model = fixture.makeModel { executable, arguments, environment in
            log.record(executable: executable, arguments: arguments, environment: environment)
            try? fixture.removeInstall()
            return .init(status: 0, stdout: "Removed the launchd agent and the relaydock binaries.\n", stderr: "")
        }
        model.refresh()
        #expect(model.state == .installed(.init(agentPlistInstalled: true, componentsOutOfDate: false)))

        await model.uninstall()

        #expect(model.state == .notInstalled)
        #expect(model.errorMessage == nil)
        #expect(log.invocations.map(\.arguments) == [["uninstall"]])
    }

    @Test func verifyPathDistinguishesWrapperShadowedAndMissing() async throws {
        let fixture = try SetupFixture()
        defer { fixture.cleanUp() }

        let ok = fixture.makeModel { _, _, _ in
            .init(status: 0, stdout: fixture.commandLinkURL.path + "\n", stderr: "")
        }
        await ok.verifyPath()
        #expect(ok.pathCheck == .ok)

        let shadowed = fixture.makeModel { _, _, _ in
            .init(status: 0, stdout: "/opt/homebrew/bin/opencode\n", stderr: "")
        }
        await shadowed.verifyPath()
        #expect(shadowed.pathCheck == .shadowed("/opt/homebrew/bin/opencode"))

        let missing = fixture.makeModel { _, _, _ in
            .init(status: 1, stdout: "", stderr: "opencode not found\n")
        }
        await missing.verifyPath()
        #expect(missing.pathCheck == .notFound)
    }

    @Test func installPassesTheConfigOverrideOnlyWhenTheStoreIsNotDefault() async throws {
        let fixture = try SetupFixture()
        defer { fixture.cleanUp() }
        let log = InvocationLog()

        let custom = fixture.makeModel { executable, arguments, environment in
            log.record(executable: executable, arguments: arguments, environment: environment)
            return .init(status: 0, stdout: "", stderr: "")
        }
        await custom.install()
        #expect(log.invocations.first?.environment["RELAYDOCK_CONFIG_DIR"] == fixture.storeDirectory.path)

        let defaultStore = fixture.home
            .appending(path: "Library/Application Support", directoryHint: .isDirectory)
            .appending(path: "com.nxhung.opencodezerolimit", directoryHint: .isDirectory)
        let defaultLog = InvocationLog()
        let defaultModel = fixture.makeModel(storeDirectory: defaultStore) { executable, arguments, environment in
            defaultLog.record(executable: executable, arguments: arguments, environment: environment)
            return .init(status: 0, stdout: "", stderr: "")
        }
        await defaultModel.install()
        #expect(defaultLog.invocations.first?.environment["RELAYDOCK_CONFIG_DIR"] == nil)
    }
}

// MARK: - Fixture

/// A throwaway home, store, and `Resources/` pair of fake bundled binaries —
/// the same shape the app bundle ships, minus the Mach-O bytes (the model
/// only checks executability and byte equality).
private struct SetupFixture: Sendable {
    let root: URL
    let home: URL
    let storeDirectory: URL
    let resourcesURL: URL

    var environment: [String: String] { ["HOME": home.path, "PATH": "/usr/bin:/bin"] }

    init(includeBundledBinaries: Bool = true) throws {
        let manager = FileManager.default
        root = manager.temporaryDirectory
            .appending(path: "relaydock-setup-\(UUID().uuidString)", directoryHint: .isDirectory)
        home = root.appending(path: "home", directoryHint: .isDirectory)
        storeDirectory = root.appending(path: "config", directoryHint: .isDirectory)
        resourcesURL = root.appending(path: "Resources", directoryHint: .isDirectory)
        for directory in [home, storeDirectory, resourcesURL] {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        if includeBundledBinaries {
            try Self.writeExecutable(resourcesURL.appending(path: "relaydock-edge"), contents: "edge v2")
            try Self.writeExecutable(resourcesURL.appending(path: "relaydock-launch"), contents: "launcher v2")
        }
    }

    var binDirectory: URL {
        home.appending(path: ".local/bin", directoryHint: .isDirectory)
    }

    var commandLinkURL: URL { binDirectory.appending(path: "opencode") }

    var agentPlistURL: URL { EdgeLaunchAgent.plistURL(environment: environment) }

    func writeInstall(componentsMatchBundle: Bool, agentPlist: Bool) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: binDirectory, withIntermediateDirectories: true)
        try Self.writeExecutable(
            binDirectory.appending(path: "relaydock-edge"),
            contents: componentsMatchBundle ? "edge v2" : "edge v1"
        )
        try Self.writeExecutable(
            binDirectory.appending(path: "relaydock-launch"),
            contents: componentsMatchBundle ? "launcher v2" : "launcher v1"
        )
        try manager.createDirectory(at: agentPlistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if agentPlist {
            try "<plist/>".write(to: agentPlistURL, atomically: true, encoding: .utf8)
        }
    }

    func removeInstall() throws {
        let manager = FileManager.default
        try? manager.removeItem(at: binDirectory)
        try? manager.removeItem(at: agentPlistURL)
    }

    @MainActor
    func makeModel(
        storeDirectory: URL? = nil,
        runProcess: @escaping RoutingSetupModel.ProcessRunner = { _, _, _ in
            RoutingSetupModel.ProcessResult(status: 0, stdout: "", stderr: "")
        }
    ) -> RoutingSetupModel {
        RoutingSetupModel(
            storeDirectory: storeDirectory ?? self.storeDirectory,
            bundledResources: resourcesURL,
            environment: environment,
            runProcess: runProcess
        )
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }

    private static func writeExecutable(_ url: URL, contents: String) throws {
        try contents.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
}

/// Records every runner invocation; the runner is `@Sendable`, so the
/// storage is lock-guarded rather than main-actor state.
private final class InvocationLog: @unchecked Sendable {
    struct Invocation {
        var executable: URL
        var arguments: [String]
        var environment: [String: String]
    }

    private let lock = NSLock()
    private var storage: [Invocation] = []

    func record(executable: URL, arguments: [String], environment: [String: String]) {
        lock.lock()
        defer { lock.unlock() }
        storage.append(Invocation(executable: executable, arguments: arguments, environment: environment))
    }

    var invocations: [Invocation] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
