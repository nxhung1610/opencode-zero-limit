import Foundation
import RelayDockCore
import Testing
@testable import RelayDockEdge

/// The launchd agent plist shape (P3 socket activation): launchd owns the
/// listeners, so `RunAtLoad` must stay false and every configured port must
/// appear as a `Sockets` entry.
struct EdgeAgentPlistTests {
    private func makeConfigDirectory(withListeners listeners: [EdgeConfigFile.Listener]) throws -> URL {
        let home = FileManager.default.temporaryDirectory
            .appending(path: "relaydock-plist-\(UUID().uuidString)", directoryHint: .isDirectory)
        let configDirectory = home.appending(path: "config", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        let config = EdgeConfigFile(port: 57211, token: "abc", listeners: listeners)
        try config.save(to: configDirectory.appending(path: "edge.json"))
        return configDirectory
    }

    @Test func plistDeclaresSocketsAndDoesNotForceRunAtLoad() throws {
        let configDirectory = try makeConfigDirectory(
            withListeners: [EdgeConfigFile.Listener(port: 57212, entryID: "px_b")]
        )
        defer { try? FileManager.default.removeItem(at: configDirectory.deletingLastPathComponent()) }
        let environment = ["RELAYDOCK_CONFIG_DIR": configDirectory.path]

        let plist = try #require(EdgeMain.agentPlist(environment: environment))
        #expect(plist["RunAtLoad"] as? Bool == false)
        #expect(plist["Label"] as? String == EdgeLaunchAgent.label)

        let sockets = try #require(plist["Sockets"] as? [String: Any])
        #expect(sockets.count == 2)
        let primary = try #require(sockets["Listeners"] as? [String: Any])
        #expect(primary["SockServiceName"] as? Int == 57211)
        #expect(primary["SockNodeName"] as? String == "127.0.0.1")
        #expect(primary["SockType"] as? String == "stream")
        let pinned = try #require(sockets["Listeners-2"] as? [String: Any])
        #expect(pinned["SockServiceName"] as? Int == 57212)

        let baked = try #require(plist["EnvironmentVariables"] as? [String: String])
        #expect(baked["RELAYDOCK_CONFIG_DIR"] == configDirectory.path)
    }

    @Test func fallsBackToRunAtLoadWithoutAConfig() throws {
        let home = FileManager.default.temporaryDirectory
            .appending(path: "relaydock-plist-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let environment = ["RELAYDOCK_CONFIG_DIR": home.appending(path: "missing").path]

        let plist = try #require(EdgeMain.agentPlist(environment: environment))
        #expect(plist["RunAtLoad"] as? Bool == true)
        #expect(plist["Sockets"] == nil)
    }
}
