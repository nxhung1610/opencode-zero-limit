import Foundation
import Testing
@testable import RelayDockCore

/// The launcher's socket-activation probe (P3): it decides whether a failed
/// ping is a wake signal (launchd holds the listener) or evidence of a dead
/// process.
struct EdgeLaunchSocketActivationTests {
    @Test func detectsSocketActivationInTheInstalledPlist() throws {
        let home = FileManager.default.temporaryDirectory
            .appending(path: "relaydock-agent-\(UUID().uuidString)", directoryHint: .isDirectory)
        let agents = home.appending(path: "Library/LaunchAgents", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let environment = ["HOME": home.path]
        let plistURL = EdgeLaunchAgent.plistURL(environment: environment)

        try Data("<plist><dict><key>Label</key><string>x</string></dict></plist>".utf8).write(to: plistURL)
        #expect(EdgeLaunchAgent.isInstalled(environment: environment))
        #expect(!EdgeLaunchAgent.usesSocketActivation(environment: environment))

        let activated: [String: Any] = ["Sockets": ["Listeners": ["SockType": "stream"]]]
        let data = try PropertyListSerialization.data(fromPropertyList: activated, format: .xml, options: 0)
        try data.write(to: plistURL)
        #expect(EdgeLaunchAgent.usesSocketActivation(environment: environment))
    }
}
