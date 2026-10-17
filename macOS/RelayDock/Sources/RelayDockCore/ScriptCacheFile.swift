import CryptoKit
import Foundation

/// Cross-process persistence for per-entry script caches (`script-cache.json`
/// next to `proxies.json`).
///
/// RelayDock Edge is the primary owner: it resolves scripts live, so one
/// process (not one per launch) shares one provider cooldown budget. During
/// P1 the app also imports this file before `checkAll()` and merges its
/// snapshots back afterwards, so an app check never re-fetches what Edge
/// already resolved and never trips the provider's cooldown for Edge's next
/// resolution. Each snapshot stores a hash of the script it was produced by,
/// so an edited script never sees stale data.
public struct ScriptCacheFile: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var scriptHash: String
        public var snapshot: String

        public init(scriptHash: String, snapshot: String) {
            self.scriptHash = scriptHash
            self.snapshot = snapshot
        }
    }

    public static let currentVersion = 1
    public static let fileName = "script-cache.json"
    /// The file the spawn-time launcher used before Edge owned the cache.
    /// Edge imports it once when `script-cache.json` does not exist yet.
    public static let legacyFileName = "launcher-cache.json"

    public var version: Int
    public var entries: [String: Entry]

    public init(version: Int = ScriptCacheFile.currentVersion, entries: [String: Entry] = [:]) {
        self.version = version
        self.entries = entries
    }

    public static func load(from url: URL) -> ScriptCacheFile {
        guard let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(ScriptCacheFile.self, from: data),
              file.version == currentVersion else {
            return ScriptCacheFile()
        }
        return file
    }

    /// Snapshots whose entry still exists and whose script is unchanged.
    public func snapshots(matching state: ProxyState) -> [String: String] {
        var result: [String: String] = [:]
        for (id, entry) in entries {
            guard let proxy = state.proxies.first(where: { $0.id == id }),
                  let script = proxy.script,
                  Self.scriptHash(script) == entry.scriptHash else { continue }
            result[id] = entry.snapshot
        }
        return result
    }

    public static func make(snapshots: [String: String], state: ProxyState) -> ScriptCacheFile {
        var file = ScriptCacheFile()
        for (id, snapshot) in snapshots {
            guard let proxy = state.proxies.first(where: { $0.id == id }),
                  let script = proxy.script else { continue }
            file.entries[id] = Entry(scriptHash: scriptHash(script), snapshot: snapshot)
        }
        return file
    }

    /// Per-entry merge where `other` wins; entries only `self` has are kept,
    /// so merging a freshly exported map over a re-loaded file never drops a
    /// snapshot another writer added meanwhile.
    public func merged(with other: ScriptCacheFile) -> ScriptCacheFile {
        var file = self
        for (id, entry) in other.entries {
            file.entries[id] = entry
        }
        return file
    }

    public func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var data = try encoder.encode(self)
        data.append(0x0A)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public static func scriptHash(_ script: String) -> String {
        SHA256.hash(data: Data(script.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
