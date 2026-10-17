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
        let config = EdgeConfigFile(port: 57212, token: "abc123")
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

        try EdgeConfigFile(version: 99, port: 57211, token: "t").save(to: url)
        #expect(EdgeConfigFile.load(from: url) == nil)
        try EdgeConfigFile(port: 0, token: "t").save(to: url)
        #expect(EdgeConfigFile.load(from: url) == nil)
        try EdgeConfigFile(port: 57211, token: "").save(to: url)
        #expect(EdgeConfigFile.load(from: url) == nil)
    }

    @Test func proxyURLIsAConstantTokenCarrierURL() {
        // The `tok:@` (colon, empty password) shape is load-bearing: Bun's
        // proxy parser ignores a bare username and OpenCode's fetch then never
        // connects. See EdgeConfigFile's doc comment.
        #expect(EdgeConfigFile(port: 57211, token: "tok").proxyURL == "http://tok:@127.0.0.1:57211")
        #expect(EdgeConfigFile.proxyURL(token: "tok", port: 1) == "http://tok:@127.0.0.1:1")
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

    @Test func tokensAreThirtyTwoHexCharactersAndUnique() {
        let first = EdgeConfigFile.makeRandomToken()
        let second = EdgeConfigFile.makeRandomToken()
        #expect(first.count == 32)
        #expect(first.allSatisfy { $0.isHexDigit })
        #expect(first != second)
    }

    @Test func defaultPortIsTheDocumentedOne() {
        #expect(EdgeConfigFile.defaultPort == 57211)
        #expect(EdgeConfigFile(port: 57211, token: "t").version == EdgeConfigFile.currentVersion)
    }
}
