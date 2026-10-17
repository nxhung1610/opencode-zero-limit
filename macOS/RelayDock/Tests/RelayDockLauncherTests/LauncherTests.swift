import Foundation
import Testing
import RelayDockCore
@testable import RelayDockLauncher

struct LauncherTests {
    // MARK: - Invocation modes

    @Test func explicitInvocationTreatsTheFirstArgumentAsTheCommand() throws {
        let target = try Launcher.targetCommand(
            invocationPath: "/opt/relaydock/relaydock-launch",
            arguments: ["opencode", "run", "hello"]
        )
        #expect(target.command == "opencode")
        #expect(target.arguments == ["run", "hello"])
    }

    @Test func symlinkedInvocationRunsTheLinkName() throws {
        let target = try Launcher.targetCommand(
            invocationPath: "/Users/example/.local/bin/opencode",
            arguments: ["serve", "--hostname", "127.0.0.1"]
        )
        #expect(target.command == "opencode")
        #expect(target.arguments == ["serve", "--hostname", "127.0.0.1"])
    }

    @Test func explicitInvocationWithoutACommandThrowsUsage() {
        #expect(throws: LauncherError.self) {
            _ = try Launcher.targetCommand(invocationPath: "/opt/relaydock-launch", arguments: [])
        }
    }

    // MARK: - PATH search

    @Test func findsTheCommandWhileSkippingTheLauncherSymlink() throws {
        let fixture = try ExecutableFixture()
        defer { fixture.cleanUp() }
        let found = Launcher.findExecutable(
            named: "opencode",
            pathValue: "\(fixture.linkDirectory.path):\(fixture.realDirectory.path)",
            skipping: [fixture.launcherRealPath]
        )
        #expect(found == fixture.realExecutablePath)
    }

    @Test func refusesToRunWhenOnlyTheLauncherItselfMatches() throws {
        let fixture = try ExecutableFixture()
        defer { fixture.cleanUp() }
        let found = Launcher.findExecutable(
            named: "opencode",
            pathValue: fixture.linkDirectory.path,
            skipping: [fixture.launcherRealPath]
        )
        #expect(found == nil)
    }

    @Test func resolvesAnExplicitPathAndRejectsTheLauncher() throws {
        let fixture = try ExecutableFixture()
        defer { fixture.cleanUp() }
        #expect(Launcher.findExecutable(named: fixture.realExecutablePath, pathValue: "", skipping: []) == fixture.realExecutablePath)
        #expect(Launcher.findExecutable(named: fixture.selfLinkPath, pathValue: "", skipping: [fixture.launcherRealPath]) == nil)
    }

    @Test func ignoresNonExecutableCandidates() throws {
        let fixture = try ExecutableFixture()
        defer { fixture.cleanUp() }
        let directory = fixture.root.appending(path: "plain", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not a command".utf8).write(to: directory.appending(path: "opencode"))
        #expect(Launcher.findExecutable(named: "opencode", pathValue: directory.path, skipping: []) == nil)
    }

    // MARK: - Routing line

    @Test func offModeLineSaysNoProxy() {
        #expect(Launcher.statusLine(status: nil) == "RelayDock: proxy mode is Off — launching without a proxy")
    }

    @Test func lineNamesTheResolvedUpstreamWhenWarm() {
        let status = EdgeStatusResponse(
            pid: 42,
            port: 57211,
            mode: .auto,
            upstream: .init(
                entryID: "px_1",
                label: "Sandbox",
                maskedURL: "•••@127.0.0.1:9009",
                source: "script",
                resolvedAt: 0
            ),
            launchedAt: 0
        )
        let line = Launcher.statusLine(status: status)
        #expect(line.contains("Edge on 127.0.0.1:57211"))
        #expect(line.contains("Sandbox"))
        #expect(line.contains("•••@127.0.0.1:9009"))
    }

    @Test func lineReportsAnActiveProviderCooldown() {
        let status = EdgeStatusResponse(
            pid: 42,
            port: 57211,
            mode: .auto,
            throttleRetryAt: Date().timeIntervalSince1970 + 30,
            launchedAt: 0
        )
        let line = Launcher.statusLine(status: status)
        #expect(line.contains("cooldown"))
    }

    @Test func lineSaysTheFirstRequestResolvesTheUpstream() {
        let status = EdgeStatusResponse(pid: 42, port: 57211, mode: .manual, launchedAt: 0)
        let line = Launcher.statusLine(status: status)
        #expect(line.contains("Manual"))
        #expect(line.contains("first request resolves the upstream"))
    }

    // MARK: - Edge binary discovery

    @Test func edgeBinaryOverrideMustBeExecutable() throws {
        let fixture = try EdgeBinaryFixture()
        defer { fixture.cleanUp() }
        let found = try EdgeClient.locateEdgeBinary(environment: ["RELAYDOCK_EDGE_BINARY": fixture.edgePath])
        #expect(found == fixture.edgePath)

        #expect(throws: EdgeClient.EdgeUnavailableError.self) {
            _ = try EdgeClient.locateEdgeBinary(environment: ["RELAYDOCK_EDGE_BINARY": fixture.nonExecutablePath])
        }
    }

    @Test func findsTheEdgeBinaryInPath() throws {
        let fixture = try EdgeBinaryFixture()
        defer { fixture.cleanUp() }
        let found = try EdgeClient.locateEdgeBinary(environment: ["PATH": fixture.directory.path])
        #expect(found == fixture.edgePath)
    }

    @Test func missingEdgeBinaryFailsClosed() {
        #expect(throws: EdgeClient.EdgeUnavailableError.self) {
            _ = try EdgeClient.locateEdgeBinary(environment: ["PATH": "/nonexistent-relaydock-fixture"])
        }
    }

    // MARK: - Fixtures

    private struct ExecutableFixture {
        let root: URL
        let linkDirectory: URL
        let realDirectory: URL
        let launcherRealPath: String
        let selfLinkPath: String
        let realExecutablePath: String

        init() throws {
            let manager = FileManager.default
            root = manager.temporaryDirectory.appending(path: "launcher-fixture-\(UUID().uuidString)", directoryHint: .isDirectory)
            linkDirectory = root.appending(path: "local-bin", directoryHint: .isDirectory)
            realDirectory = root.appending(path: "real-bin", directoryHint: .isDirectory)
            try manager.createDirectory(at: linkDirectory, withIntermediateDirectories: true)
            try manager.createDirectory(at: realDirectory, withIntermediateDirectories: true)

            let launcherFile = root.appending(path: "relaydock-launch")
            manager.createFile(atPath: launcherFile.path, contents: Data("#!/bin/sh\nexit 0\n".utf8))
            try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcherFile.path)
            launcherRealPath = Launcher.resolvedPath(launcherFile.path)

            selfLinkPath = linkDirectory.appending(path: "opencode").path
            try manager.createSymbolicLink(atPath: selfLinkPath, withDestinationPath: launcherFile.path)

            realExecutablePath = realDirectory.appending(path: "opencode").path
            manager.createFile(atPath: realExecutablePath, contents: Data("#!/bin/sh\nexit 0\n".utf8))
            try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: realExecutablePath)
        }

        func cleanUp() {
            try? FileManager.default.removeItem(at: root)
        }
    }

    private struct EdgeBinaryFixture {
        let directory: URL
        let edgePath: String
        let nonExecutablePath: String

        init() throws {
            let manager = FileManager.default
            directory = manager.temporaryDirectory.appending(path: "edge-binary-\(UUID().uuidString)", directoryHint: .isDirectory)
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            edgePath = directory.appending(path: "relaydock-edge").path
            manager.createFile(atPath: edgePath, contents: Data("#!/bin/sh\nexit 0\n".utf8))
            try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: edgePath)
            nonExecutablePath = directory.appending(path: "not-executable").path
            manager.createFile(atPath: nonExecutablePath, contents: Data("plain".utf8))
            try manager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: nonExecutablePath)
        }

        func cleanUp() {
            try? FileManager.default.removeItem(at: directory)
        }
    }
}
