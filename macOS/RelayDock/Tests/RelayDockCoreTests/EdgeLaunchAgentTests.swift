import Darwin
import Foundation
import Testing
@testable import RelayDockCore

/// `EdgeLaunchAgent` drives launchctl, so every test points
/// `RELAYDOCK_LAUNCHCTL` at a fake script that records its arguments and
/// serves exit codes from a queue. The real login session is never touched.
@Suite struct EdgeLaunchAgentTests {
    @Test func plistURLHonorsHomeOverride() {
        let url = EdgeLaunchAgent.plistURL(environment: ["HOME": "/tmp/relaydock-test-home"])
        #expect(url.path == "/tmp/relaydock-test-home/Library/LaunchAgents/com.nxhung.relaydock.edge.plist")
    }

    @Test func managedConfigDirectoryReadsTheBakedOverride() throws {
        let fixture = try AgentFixture()
        defer { fixture.cleanUp() }
        try fixture.writePlist(environmentVariables: ["RELAYDOCK_CONFIG_DIR": "/tmp/relaydock-other-config"])

        let managed = EdgeLaunchAgent.managedConfigDirectory(environment: fixture.environment)

        #expect(managed.path == "/tmp/relaydock-other-config")
    }

    @Test func managedConfigDirectoryDefaultsToTheAppSupportFolder() throws {
        let fixture = try AgentFixture()
        defer { fixture.cleanUp() }
        try fixture.writePlist(environmentVariables: nil)

        let managed = EdgeLaunchAgent.managedConfigDirectory(environment: fixture.environment)

        let expected = fixture.home
            .appending(path: "Library/Application Support", directoryHint: .isDirectory)
            .appending(path: "com.nxhung.opencodezerolimit", directoryHint: .isDirectory)
        #expect(managed.path == expected.path)
    }

    @Test func managesRequiresAnInstalledMatchingPlist() throws {
        let fixture = try AgentFixture()
        defer { fixture.cleanUp() }

        #expect(!EdgeLaunchAgent.manages(configDirectory: fixture.config, environment: fixture.environment))

        try fixture.writePlist(environmentVariables: ["RELAYDOCK_CONFIG_DIR": fixture.config.path])
        #expect(EdgeLaunchAgent.manages(configDirectory: fixture.config, environment: fixture.environment))

        try fixture.writePlist(environmentVariables: ["RELAYDOCK_CONFIG_DIR": "/tmp/relaydock-elsewhere"])
        #expect(!EdgeLaunchAgent.manages(configDirectory: fixture.config, environment: fixture.environment))
    }

    @Test func activateKickstartsALoadedJob() throws {
        let fixture = try AgentFixture()
        defer { fixture.cleanUp() }
        try fixture.writePlist(environmentVariables: ["RELAYDOCK_CONFIG_DIR": fixture.config.path])
        try fixture.fakeLaunchctl.setExitCodes([0, 0])

        let activated = EdgeLaunchAgent.activate(configDirectory: fixture.config, environment: fixture.environment)

        #expect(activated)
        let record = try fixture.fakeLaunchctl.record()
        #expect(record.contains("print gui/\(getuid())/com.nxhung.relaydock.edge"))
        #expect(record.contains("kickstart -k gui/\(getuid())/com.nxhung.relaydock.edge"))
    }

    @Test func activateBootstrapsWhenTheJobIsNotLoaded() throws {
        let fixture = try AgentFixture()
        defer { fixture.cleanUp() }
        try fixture.writePlist(environmentVariables: ["RELAYDOCK_CONFIG_DIR": fixture.config.path])
        try fixture.fakeLaunchctl.setExitCodes([1, 0])

        let activated = EdgeLaunchAgent.activate(configDirectory: fixture.config, environment: fixture.environment)

        #expect(activated)
        let record = try fixture.fakeLaunchctl.record()
        let plistPath = EdgeLaunchAgent.plistURL(environment: fixture.environment).path
        #expect(record.contains("bootstrap gui/\(getuid()) \(plistPath)"))
    }

    @Test func activateReturnsFalseWhenKickstartFails() throws {
        let fixture = try AgentFixture()
        defer { fixture.cleanUp() }
        try fixture.writePlist(environmentVariables: ["RELAYDOCK_CONFIG_DIR": fixture.config.path])
        try fixture.fakeLaunchctl.setExitCodes([0, 1])

        let activated = EdgeLaunchAgent.activate(configDirectory: fixture.config, environment: fixture.environment)

        #expect(!activated)
    }

    @Test func activateRefusesAForeignConfigDirectory() throws {
        let fixture = try AgentFixture()
        defer { fixture.cleanUp() }
        try fixture.writePlist(environmentVariables: ["RELAYDOCK_CONFIG_DIR": "/tmp/relaydock-elsewhere"])
        try fixture.fakeLaunchctl.setExitCodes([0, 0])

        let activated = EdgeLaunchAgent.activate(configDirectory: fixture.config, environment: fixture.environment)

        #expect(!activated)
        #expect(try fixture.fakeLaunchctl.record().isEmpty)
    }

    @Test func bootoutUnloadsTheJob() throws {
        let fixture = try AgentFixture()
        defer { fixture.cleanUp() }
        try fixture.fakeLaunchctl.setExitCodes([0])

        let bootedOut = EdgeLaunchAgent.bootout(environment: fixture.environment)

        #expect(bootedOut)
        #expect(try fixture.fakeLaunchctl.record().contains("bootout gui/\(getuid())/com.nxhung.relaydock.edge"))
    }

    /// The installer (bash) must drive the same agent label the Swift side
    /// boots out and kickstarts; drift breaks stop/kickstart silently.
    @Test func installerScriptPinsTheSameAgentLabel() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let script = try String(
            contentsOf: repoRoot.appending(path: "scripts/opencode-wrapper.sh"),
            encoding: .utf8
        )
        #expect(script.contains("com.nxhung.relaydock.edge"))
    }
}

private struct AgentFixture {
    let root: URL
    let home: URL
    let config: URL
    let fakeLaunchctl: FakeLaunchctl

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "relaydock-agent-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        home = root.appending(path: "home", directoryHint: .isDirectory)
        config = root.appending(path: "config", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        fakeLaunchctl = FakeLaunchctl(root: root)
        try fakeLaunchctl.writeScript()
    }

    var environment: [String: String] {
        [
            "HOME": home.path,
            "RELAYDOCK_CONFIG_DIR": config.path,
            "RELAYDOCK_LAUNCHCTL": fakeLaunchctl.scriptURL.path,
            "PATH": "/usr/bin:/bin",
        ]
    }

    func writePlist(environmentVariables: [String: String]?) throws {
        var plist: [String: Any] = [
            "Label": EdgeLaunchAgent.label,
            "ProgramArguments": ["/usr/local/bin/relaydock-edge", "run"],
        ]
        if let environmentVariables {
            plist["EnvironmentVariables"] = environmentVariables
        }
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        let url = EdgeLaunchAgent.plistURL(environment: environment)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url)
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }
}

private struct FakeLaunchctl {
    let root: URL

    var scriptURL: URL { root.appending(path: "fake-launchctl") }
    private var recordURL: URL { root.appending(path: "launchctl-record") }
    private var codesURL: URL { root.appending(path: "launchctl-codes") }
    private var countURL: URL { root.appending(path: "launchctl-count") }

    func setExitCodes(_ codes: [Int32]) throws {
        let text = codes.map(String.init).joined(separator: "\n") + "\n"
        try text.write(to: codesURL, atomically: true, encoding: .utf8)
    }

    func record() throws -> String {
        (try? String(contentsOf: recordURL, encoding: .utf8)) ?? ""
    }

    func writeScript() throws {
        let script = """
        #!/bin/bash
        echo "$@" >> "\(recordURL.path)"
        count=0
        if [[ -f "\(countURL.path)" ]]; then count=$(cat "\(countURL.path)"); fi
        count=$((count + 1))
        echo "$count" > "\(countURL.path)"
        code=$(sed -n "${count}p" "\(codesURL.path)" 2>/dev/null)
        if [[ -z "$code" ]]; then code=0; fi
        exit "$code"
        """
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
    }
}
