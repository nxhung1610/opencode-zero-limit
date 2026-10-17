import Foundation
import Testing
@testable import RelayDockCore

struct ScriptCacheFileTests {
    private func sandboxState(script: String) -> ProxyState {
        ProxyState(
            mode: .auto,
            proxies: [ProxyEntry(id: "px_sandbox", label: "Sandbox", url: "", script: script)]
        )
    }

    private func temporaryFileURL() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "script-cache-\(UUID().uuidString).json")
    }

    @Test func roundTripsThroughDisk() throws {
        let url = temporaryFileURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let state = sandboxState(script: "return \"http://127.0.0.1:9101\";")
        let file = ScriptCacheFile.make(snapshots: ["px_sandbox": #"{"url":"http://127.0.0.1:9101"}"#], state: state)
        try file.save(to: url)

        let loaded = ScriptCacheFile.load(from: url).snapshots(matching: state)
        #expect(loaded["px_sandbox"] == #"{"url":"http://127.0.0.1:9101"}"#)

        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect(attributes[.posixPermissions] as? Int == 0o600)
    }

    @Test func rejectsSnapshotsFromAnEditedScript() throws {
        let url = temporaryFileURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let file = ScriptCacheFile.make(
            snapshots: ["px_sandbox": #"{"url":"http://stale"}"#],
            state: sandboxState(script: "return \"http://old\";")
        )
        try file.save(to: url)

        let edited = sandboxState(script: "return \"http://new\";")
        #expect(ScriptCacheFile.load(from: url).snapshots(matching: edited).isEmpty)
    }

    @Test func dropsEntriesThatLeftThePool() throws {
        let url = temporaryFileURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let state = ProxyState(mode: .auto, proxies: [
            ProxyEntry(id: "px_keep", label: "Keep", url: "", script: "echo keep"),
            ProxyEntry(id: "px_drop", label: "Drop", url: "", script: "echo drop"),
        ])
        let file = ScriptCacheFile.make(
            snapshots: ["px_keep": "{\"a\":1}", "px_drop": "{\"b\":2}"],
            state: state
        )
        try file.save(to: url)

        let smaller = ProxyState(mode: .auto, proxies: [
            ProxyEntry(id: "px_keep", label: "Keep", url: "", script: "echo keep")
        ])
        let snapshots = ScriptCacheFile.load(from: url).snapshots(matching: smaller)
        #expect(snapshots == ["px_keep": "{\"a\":1}"])
    }

    @Test func damagedOrMissingFileLoadsEmpty() throws {
        let url = temporaryFileURL()
        #expect(ScriptCacheFile.load(from: url).entries.isEmpty)

        try Data("not json{".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(ScriptCacheFile.load(from: url).entries.isEmpty)
    }

    @Test func mergeKeepsEntriesOnlyTheOtherSideHasAndLetsTheOtherSideWin() {
        let first = ScriptCacheFile(entries: [
            "shared": .init(scriptHash: "h1", snapshot: "old"),
            "only-first": .init(scriptHash: "h2", snapshot: "kept"),
        ])
        let second = ScriptCacheFile(entries: [
            "shared": .init(scriptHash: "h1", snapshot: "new"),
            "only-second": .init(scriptHash: "h3", snapshot: "added"),
        ])
        let merged = first.merged(with: second)
        #expect(merged.entries["shared"]?.snapshot == "new")
        #expect(merged.entries["only-first"]?.snapshot == "kept")
        #expect(merged.entries["only-second"]?.snapshot == "added")
    }

    @Test func legacyFileNameMatchesThePreEdgeFile() {
        #expect(ScriptCacheFile.fileName == "script-cache.json")
        #expect(ScriptCacheFile.legacyFileName == "launcher-cache.json")
    }
}
