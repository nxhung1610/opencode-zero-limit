import CryptoKit
import Foundation
import RelayDockCore

/// Cross-process persistence for per-entry script caches (`launcher-cache.json`
/// next to `proxies.json`).
///
/// The launcher runs in a fresh process per launch, so the in-memory script
/// cache inside `RelayDockCore` cannot bridge launches by itself. The file
/// stores each snapshot with a hash of the script it was produced by, so an
/// edited script never sees a stale cache left by a previous definition.
struct LauncherCacheFile: Codable, Equatable {
    struct Entry: Codable, Equatable {
        var scriptHash: String
        var snapshot: String
    }

    var version: Int
    var entries: [String: Entry]

    init(version: Int = 1, entries: [String: Entry] = [:]) {
        self.version = version
        self.entries = entries
    }

    static func load(from url: URL) -> LauncherCacheFile {
        guard let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(LauncherCacheFile.self, from: data),
              file.version == 1 else {
            return LauncherCacheFile()
        }
        return file
    }

    /// Snapshots whose entry still exists and whose script is unchanged.
    func snapshots(matching state: ProxyState) -> [String: String] {
        var result: [String: String] = [:]
        for (id, entry) in entries {
            guard let proxy = state.proxies.first(where: { $0.id == id }),
                  let script = proxy.script,
                  Self.scriptHash(script) == entry.scriptHash else { continue }
            result[id] = entry.snapshot
        }
        return result
    }

    static func make(snapshots: [String: String], state: ProxyState) -> LauncherCacheFile {
        var file = LauncherCacheFile()
        for (id, snapshot) in snapshots {
            guard let proxy = state.proxies.first(where: { $0.id == id }),
                  let script = proxy.script else { continue }
            file.entries[id] = Entry(scriptHash: scriptHash(script), snapshot: snapshot)
        }
        return file
    }

    func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var data = try encoder.encode(self)
        data.append(0x0A)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    static func scriptHash(_ script: String) -> String {
        SHA256.hash(data: Data(script.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
