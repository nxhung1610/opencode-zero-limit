import Foundation
import Testing
@testable import RelayDockCore

struct EdgeConfigFileTests {
    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "edge-config-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    @Test func roundTripsAndRestrictsPermissions() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "edge.json")
        let config = EdgeConfigFile(port: 57212)
        try config.save(to: url)

        #expect(EdgeConfigFile.load(from: url) == config)
        let fileAttributes = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect(fileAttributes[.posixPermissions] as? Int == 0o600)
        let directoryAttributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        #expect(directoryAttributes[.posixPermissions] as? Int == 0o700)
    }

    @Test func rejectsDamagedOrIncompatibleFiles() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "edge.json")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        #expect(EdgeConfigFile.load(from: url) == nil)
        try Data("not json".utf8).write(to: url)
        #expect(EdgeConfigFile.load(from: url) == nil)

        try EdgeConfigFile(version: 99, port: 57211).save(to: url)
        #expect(EdgeConfigFile.load(from: url) == nil)
        try EdgeConfigFile(port: 0).save(to: url)
        #expect(EdgeConfigFile.load(from: url) == nil)
    }

    /// A v0.4.0 file carries a `token` key that no longer exists in the model;
    /// decoding must ignore it so upgrades never strand a working install.
    @Test func legacyTokenKeyIsIgnored() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "edge.json")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(#"{"version":1,"port":57211,"token":"deadbeef"}"#.utf8).write(to: url)

        let config = try #require(EdgeConfigFile.load(from: url))
        #expect(config.port == 57211)
        #expect(config.listeners.isEmpty)
    }

    @Test func savedFileCarriesNoToken() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "edge.json")
        try EdgeConfigFile(port: 57211).save(to: url)

        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(!text.contains("token"))
    }

    @Test func proxyURLPointsAtTheLoopbackPort() {
        #expect(EdgeConfigFile(port: 57211).proxyURL == "http://127.0.0.1:57211")
        #expect(EdgeConfigFile.proxyURL(port: 1) == "http://127.0.0.1:1")
    }

    @Test func configDirectoryHonorsEnvironmentOverrides() {
        let override = EdgeConfigFile.configDirectory(environment: ["RELAYDOCK_CONFIG_DIR": "/tmp/relaydock-fixture"])
        #expect(override.path == "/tmp/relaydock-fixture")

        let byHome = EdgeConfigFile.configDirectory(environment: ["HOME": "/Users/example"])
        #expect(byHome.path == "/Users/example/Library/Application Support/com.nxhung.opencodezerolimit")

        let fileURL = EdgeConfigFile.fileURL(
            configDirectory: URL(fileURLWithPath: "/tmp/relaydock-fixture", isDirectory: true),
            environment: [:]
        )
        #expect(fileURL.path == "/tmp/relaydock-fixture/edge.json")
    }

    @Test func defaultPortIsTheDocumentedOne() {
        #expect(EdgeConfigFile.defaultPort == 57211)
        #expect(EdgeConfigFile(port: 57211).version == EdgeConfigFile.currentVersion)
    }
}
