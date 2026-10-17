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

    // MARK: - Cache file

    @Test func cacheFileRoundTripsThroughDisk() throws {
        let state = sandboxState(script: "return \"http://127.0.0.1:1\";")
        let file = LauncherCacheFile.make(snapshots: ["px_sandbox": "{\"url\":\"http://127.0.0.1:9009\"}"], state: state)
        let url = FileManager.default.temporaryDirectory.appending(path: "launcher-cache-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        try file.save(to: url)
        let loaded = LauncherCacheFile.load(from: url)
        #expect(loaded.snapshots(matching: state) == ["px_sandbox": "{\"url\":\"http://127.0.0.1:9009\"}"])
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(permissions == 0o600)
    }

    @Test func cacheFileRejectsSnapshotsFromAnEditedScript() throws {
        let snapshot = "{\"url\":\"http://127.0.0.1:9009\"}"
        let before = sandboxState(script: "return \"http://127.0.0.1:1\";")
        let file = LauncherCacheFile.make(snapshots: ["px_sandbox": snapshot], state: before)
        let after = sandboxState(script: "return \"http://127.0.0.1:2\";")
        #expect(file.snapshots(matching: after).isEmpty)
    }

    @Test func cacheFileDropsEntriesThatLeftThePool() throws {
        let file = LauncherCacheFile.make(
            snapshots: ["px_gone": "{\"url\":\"http://x:1\"}"],
            state: ProxyState(mode: .auto, proxies: [])
        )
        #expect(file.entries.isEmpty)
    }

    @Test func damagedOrMissingCacheFileLoadsEmpty() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "launcher-cache-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("not json".utf8).write(to: url)
        #expect(LauncherCacheFile.load(from: url).entries.isEmpty)
        #expect(LauncherCacheFile.load(from: url.appendingPathExtension("missing")).entries.isEmpty)
    }

    // MARK: - Fixtures

    private func sandboxState(script: String) -> ProxyState {
        ProxyState(
            mode: .auto,
            proxies: [ProxyEntry(id: "px_sandbox", label: "Sandbox", url: "", script: script)]
        )
    }

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
}
