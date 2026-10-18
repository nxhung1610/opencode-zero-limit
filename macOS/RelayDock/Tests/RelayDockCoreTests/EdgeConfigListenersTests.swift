import Foundation
import Testing
@testable import RelayDockCore

/// `edge.json` listener entries (P3 per-account ports): absent on older
/// files, decoded tolerantly, and hardened at load time so one bad pin can
/// never take the primary listener down with it.
struct EdgeConfigListenersTests {
    private func write(_ json: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "relaydock-config-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "edge.json")
        try Data(json.utf8).write(to: url)
        return url
    }

    @Test func decodesConfigsWithoutListeners() throws {
        let url = try write(#"{"version":1,"port":57211,"token":"abc"}"#)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let config = EdgeConfigFile.load(from: url)
        #expect(config?.listeners.isEmpty == true)
    }

    @Test func decodesPinnedListeners() throws {
        let url = try write(#"{"version":1,"port":57211,"token":"abc","listeners":[{"port":57212,"entryID":"px_b"}]}"#)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let config = EdgeConfigFile.load(from: url)
        #expect(config?.listeners == [EdgeConfigFile.Listener(port: 57212, entryID: "px_b")])
    }

    @Test func dropsInvalidListenerEntriesWithoutFailingTheFile() throws {
        let url = try write("""
        {"version":1,"port":57211,"token":"abc","listeners":[
          {"port":0,"entryID":"px_a"},
          {"port":57211,"entryID":"px_dupPrimary"},
          {"port":57213,"entryID":"  "},
          {"port":57212,"entryID":"px_ok"},
          {"port":57212,"entryID":"px_dup"}
        ]}
        """)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let config = EdgeConfigFile.load(from: url)
        #expect(config?.listeners == [EdgeConfigFile.Listener(port: 57212, entryID: "px_ok")])
    }

    @Test func roundTripsListenersThroughSave() throws {
        let url = try write(#"{"version":1,"port":57211,"token":"abc"}"#)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var config = try #require(EdgeConfigFile.load(from: url))
        config.listeners = [EdgeConfigFile.Listener(port: 57212, entryID: "px_b")]
        try config.save(to: url)
        #expect(EdgeConfigFile.load(from: url)?.listeners == config.listeners)
    }
}
