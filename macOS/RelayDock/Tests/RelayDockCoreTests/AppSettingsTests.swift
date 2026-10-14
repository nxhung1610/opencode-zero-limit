import Foundation
import Testing
@testable import RelayDockCore

struct AppSettingsTests {
    @Test func decodesExistingSettingsAndSnakeCaseAliases() throws {
        let camel = Data(#"{"autoRotate":true,"autoStart":false,"opencodeBin":"/opt/opencode","theme":"light"}"#.utf8)
        let snake = Data(#"{"auto_rotate":true,"auto_start":false,"opencode_bin":"/opt/opencode","theme":"system"}"#.utf8)

        #expect(try JSONDecoder().decode(AppSettings.self, from: camel) == AppSettings(autoRotate: true, autoStart: false, opencodeBin: "/opt/opencode", theme: "light"))
        #expect(try JSONDecoder().decode(AppSettings.self, from: snake) == AppSettings(autoRotate: true, autoStart: false, opencodeBin: "/opt/opencode", theme: "system"))
    }

    @Test func settingsStorePersistsAndKeepsCorruptFile() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SettingsStore(configDirectory: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not-json".utf8).write(to: store.fileURL)

        let settings = AppSettings(autoRotate: true, autoStart: false, opencodeBin: "/tmp/opencode", theme: "system")
        try store.save(settings)

        #expect(store.load() == settings)
        let siblingFiles = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(siblingFiles.contains(where: { $0.hasPrefix("settings.json.corrupt-") }))
        let directoryMode = try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber
        let fileMode = try FileManager.default.attributesOfItem(atPath: store.fileURL.path)[.posixPermissions] as? NSNumber
        #expect(directoryMode?.intValue == 0o700)
        #expect(fileMode?.intValue == 0o600)
    }

    @Test func usesTheLegacyMacConfigurationNamespace() {
        let path = SettingsStore(environment: ["HOME": "/Users/example"]).fileURL.path
        #expect(path == "/Users/example/Library/Application Support/com.nxhung.opencodezerolimit/settings.json")
    }
}
