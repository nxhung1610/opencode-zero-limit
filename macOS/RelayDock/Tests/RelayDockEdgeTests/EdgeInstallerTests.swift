import Darwin
import Foundation
import RelayDockCore
import Testing
@testable import RelayDockEdge

/// `EdgeInstaller` drives the filesystem, launchctl, and (optionally) a
/// running Edge, so every test builds a hermetic HOME/config/source fixture,
/// points `RELAYDOCK_LAUNCHCTL` at a fake script, and stubs the status probe
/// and the stop helper. The real login session and user data are never
/// touched.
@Suite struct EdgeInstallerTests {
    @Test func installCopiesBinariesLinksTheWrapperAndWritesTheAgent() throws {
        let fixture = try InstallFixture()
        defer { fixture.cleanUp() }
        let output = OutputCapture()

        let code = fixture.makeInstaller(output: output)
            .install(sourceLauncher: fixture.launcherSource, sourceEdge: fixture.edgeSource)

        #expect(code == 0)
        let installedLauncher = fixture.binDirectory.appending(path: "relaydock-launch")
        let installedEdge = fixture.binDirectory.appending(path: "relaydock-edge")
        #expect(FileManager.default.isExecutableFile(atPath: installedLauncher.path))
        #expect(FileManager.default.isExecutableFile(atPath: installedEdge.path))
        let linkTarget = try FileManager.default.destinationOfSymbolicLink(
            atPath: fixture.binDirectory.appending(path: "opencode").path
        )
        #expect(linkTarget == installedLauncher.path)

        let config = try #require(EdgeConfigFile.load(from: fixture.config.appending(path: "edge.json")))
        #expect((57_211...57_230).contains(config.port))

        let plistURL = EdgeLaunchAgent.plistURL(environment: fixture.environment)
        let plistData = try Data(contentsOf: plistURL)
        let plist = try #require(
            try PropertyListSerialization.propertyList(from: plistData, options: [], format: nil) as? [String: Any]
        )
        #expect(plist["Label"] as? String == EdgeLaunchAgent.label)
        #expect(plist["ProgramArguments"] as? [String] == [installedEdge.path, "run"])
        #expect((plist["Sockets"] as? [String: Any])?.count == 1)
        #expect(
            (plist["EnvironmentVariables"] as? [String: String])?["RELAYDOCK_CONFIG_DIR"]
                == fixture.config.path
        )

        let record = try fixture.fakeLaunchctl.record()
        #expect(record.contains("bootout gui/\(getuid())/\(EdgeLaunchAgent.label)"))
        #expect(record.contains("bootstrap gui/\(getuid()) \(plistURL.path)"))
        #expect(output.text.contains("running under launchd agent \(EdgeLaunchAgent.label)"))
        #expect(output.text.contains("OK: 'opencode' resolves to the wrapper."))
        #expect(output.text.contains("Installed OpenCode free-usage limit monitor plugin."))
        #expect(try String(contentsOf: fixture.openCodePlugin, encoding: .utf8).contains("test plugin payload"))
    }

    @Test func installKeepsAnExistingEdgeConfig() throws {
        let fixture = try InstallFixture()
        defer { fixture.cleanUp() }
        try EdgeConfigFile(port: 59_999)
            .save(to: fixture.config.appending(path: "edge.json"))
        let output = OutputCapture()

        let code = fixture.makeInstaller(output: output)
            .install(sourceLauncher: fixture.launcherSource, sourceEdge: fixture.edgeSource)

        #expect(code == 0)
        let config = try #require(EdgeConfigFile.load(from: fixture.config.appending(path: "edge.json")))
        #expect(config.port == 59_999)
        #expect(output.text.contains("already configured (port 59999)"))
    }

    @Test func installRefusesToReplaceANonSymlinkOpencode() throws {
        let fixture = try InstallFixture()
        defer { fixture.cleanUp() }
        try FileManager.default.createDirectory(at: fixture.binDirectory, withIntermediateDirectories: true)
        try "not ours".write(
            to: fixture.binDirectory.appending(path: "opencode"), atomically: true, encoding: .utf8
        )
        let output = OutputCapture()

        let code = fixture.makeInstaller(output: output)
            .install(sourceLauncher: fixture.launcherSource, sourceEdge: fixture.edgeSource)

        #expect(code == 1)
        #expect(output.errorText.contains("is not a symlink"))
        #expect(!FileManager.default.fileExists(
            atPath: fixture.binDirectory.appending(path: "relaydock-launch").path
        ))
        #expect(!FileManager.default.fileExists(atPath: fixture.config.appending(path: "edge.json").path))
    }

    @Test func installWarnsWhenEdgeNeverReportsReady() throws {
        let fixture = try InstallFixture()
        defer { fixture.cleanUp() }
        let output = OutputCapture()

        let code = fixture.makeInstaller(output: output, statusProbe: { _ in false }, statusWait: 0)
            .install(sourceLauncher: fixture.launcherSource, sourceEdge: fixture.edgeSource)

        #expect(code == 0)
        #expect(output.errorText.contains("has not reported ready"))
        #expect(!output.text.contains("running under launchd agent"))
    }

    @Test func installStopsAPreviouslyInstalledEdge() throws {
        let fixture = try InstallFixture()
        defer { fixture.cleanUp() }
        let output = OutputCapture()
        var stopped: [URL] = []
        let installer = fixture.makeInstaller(output: output, stopInstalledEdge: { stopped.append($0) })

        _ = installer.install(sourceLauncher: fixture.launcherSource, sourceEdge: fixture.edgeSource)
        #expect(stopped.isEmpty)

        _ = installer.install(sourceLauncher: fixture.launcherSource, sourceEdge: fixture.edgeSource)
        #expect(stopped == [fixture.binDirectory.appending(path: "relaydock-edge")])
    }

    @Test func uninstallRemovesTheInstallAndKeepsUserData() throws {
        let fixture = try InstallFixture()
        defer { fixture.cleanUp() }
        let output = OutputCapture()
        var stopped: [URL] = []
        let installer = fixture.makeInstaller(output: output, stopInstalledEdge: { stopped.append($0) })
        _ = installer.install(sourceLauncher: fixture.launcherSource, sourceEdge: fixture.edgeSource)
        try "{}".write(
            to: fixture.config.appending(path: "proxies.json"), atomically: true, encoding: .utf8
        )

        let code = installer.uninstall()

        #expect(code == 0)
        #expect(!FileManager.default.fileExists(
            atPath: fixture.binDirectory.appending(path: "opencode").path
        ))
        #expect(!FileManager.default.fileExists(
            atPath: fixture.binDirectory.appending(path: "relaydock-launch").path
        ))
        #expect(!FileManager.default.fileExists(
            atPath: fixture.binDirectory.appending(path: "relaydock-edge").path
        ))
        #expect(!FileManager.default.fileExists(atPath: fixture.config.appending(path: "edge.json").path))
        #expect(!FileManager.default.fileExists(
            atPath: EdgeLaunchAgent.plistURL(environment: fixture.environment).path
        ))
        #expect(FileManager.default.fileExists(atPath: fixture.config.appending(path: "proxies.json").path))
        #expect(!FileManager.default.fileExists(atPath: fixture.openCodePlugin.path))
        #expect(stopped.contains(fixture.binDirectory.appending(path: "relaydock-edge")))
        #expect(output.text.contains("Removed launchd agent"))
        #expect(output.text.contains("Removed \(fixture.binDirectory.appending(path: "opencode").path)"))
        #expect(output.text.contains("Removed OpenCode free-usage limit monitor plugin."))
        #expect(output.text.contains("Kept the proxy pool"))
    }

    @Test func installPreservesUnrelatedOpenCodePluginWithSameName() throws {
        let fixture = try InstallFixture()
        defer { fixture.cleanUp() }
        try FileManager.default.createDirectory(
            at: fixture.openCodePlugin.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try "// a user's plugin\n".write(to: fixture.openCodePlugin, atomically: true, encoding: .utf8)
        let output = OutputCapture()

        let code = fixture.makeInstaller(output: output)
            .install(sourceLauncher: fixture.launcherSource, sourceEdge: fixture.edgeSource)

        #expect(code == 0)
        #expect(try String(contentsOf: fixture.openCodePlugin, encoding: .utf8) == "// a user's plugin\n")
        #expect(output.errorText.contains("preserving unrelated OpenCode plugin"))
    }

    @Test func uninstallWithoutAnInstallSucceedsQuietly() throws {
        let fixture = try InstallFixture()
        defer { fixture.cleanUp() }
        let output = OutputCapture()

        let code = fixture.makeInstaller(output: output).uninstall()

        #expect(code == 0)
        #expect(output.text.contains("No wrapper symlink at"))
        #expect(!output.text.contains("Removed launchd agent"))
        #expect(output.errorText.isEmpty)
    }

    @Test func installReportsAnEarlierOpencodeInPath() throws {
        let fixture = try InstallFixture()
        defer { fixture.cleanUp() }
        let earlier = fixture.root.appending(path: "earlier-bin", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: earlier, withIntermediateDirectories: true)
        let earlierOpencode = earlier.appending(path: "opencode")
        try "#!/bin/sh\n".write(to: earlierOpencode, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: earlierOpencode.path
        )
        let output = OutputCapture()

        let code = fixture.makeInstaller(output: output, path: "\(earlier.path):/usr/bin:/bin")
            .install(sourceLauncher: fixture.launcherSource, sourceEdge: fixture.edgeSource)

        #expect(code == 0)
        #expect(output.errorText.contains("an earlier PATH entry wins"))
        #expect(output.errorText.contains("is not in PATH"))
    }
}

private struct InstallFixture {
    let root: URL
    let home: URL
    let config: URL
    let fakeLaunchctl: FakeLaunchctl

    init() throws {
        let manager = FileManager.default
        root = manager.temporaryDirectory
            .appending(path: "relaydock-installer-\(UUID().uuidString)", directoryHint: .isDirectory)
        home = root.appending(path: "home", directoryHint: .isDirectory)
        config = root.appending(path: "config", directoryHint: .isDirectory)
        let sources = root.appending(path: "build", directoryHint: .isDirectory)
        for directory in [home, config, sources] {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        for name in ["relaydock-launch", "relaydock-edge"] {
            let url = sources.appending(path: name)
            try "#!/bin/sh\n".write(to: url, atomically: true, encoding: .utf8)
            try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        try "// RelayDock-managed plugin.\n// test plugin payload\n".write(
            to: sources.appending(path: "relaydock-free-usage-limit.js"), atomically: true, encoding: .utf8
        )
        fakeLaunchctl = FakeLaunchctl(root: root)
        try fakeLaunchctl.writeScript()
    }

    var launcherSource: URL { root.appending(path: "build/relaydock-launch") }
    var edgeSource: URL { root.appending(path: "build/relaydock-edge") }
    var openCodePlugin: URL {
        home.appending(path: ".config/opencode/plugins/relaydock-free-usage-limit.js")
    }
    var binDirectory: URL { home.appending(path: ".local/bin", directoryHint: .isDirectory) }

    var environment: [String: String] {
        [
            "HOME": home.path,
            "RELAYDOCK_CONFIG_DIR": config.path,
            "RELAYDOCK_LAUNCHCTL": fakeLaunchctl.scriptURL.path,
            "PATH": "\(binDirectory.path):/usr/bin:/bin",
        ]
    }

    func makeInstaller(
        output: OutputCapture,
        statusProbe: @escaping (EdgeConfigFile) -> Bool = { _ in true },
        statusWait: TimeInterval = 0,
        stopInstalledEdge: @escaping (URL) -> Void = { _ in },
        path: String? = nil
    ) -> EdgeInstaller {
        var environment = environment
        if let path { environment["PATH"] = path }
        var installer = EdgeInstaller(environment: environment)
        installer.statusWait = statusWait
        installer.statusProbe = statusProbe
        installer.stopInstalledEdge = stopInstalledEdge
        installer.stdout = { output.lines.append($0) }
        installer.stderr = { output.errors.append($0) }
        installer.sleep = { _ in }
        return installer
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }
}

private final class OutputCapture {
    var lines: [String] = []
    var errors: [String] = []
    var text: String { lines.joined(separator: "\n") }
    var errorText: String { errors.joined(separator: "\n") }
}

private struct FakeLaunchctl {
    let root: URL

    var scriptURL: URL { root.appending(path: "fake-launchctl") }
    private var recordURL: URL { root.appending(path: "launchctl-record") }

    func writeScript() throws {
        let script = """
        #!/bin/bash
        echo "$@" >> "\(recordURL.path)"
        exit 0
        """
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
    }

    func record() throws -> String {
        (try? String(contentsOf: recordURL, encoding: .utf8)) ?? ""
    }
}
