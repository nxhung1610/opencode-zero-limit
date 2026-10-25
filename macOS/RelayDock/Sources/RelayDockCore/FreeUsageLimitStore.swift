import Foundation

/// Edge-owned cooldowns for proxy entries that received an OpenCode free-tier
/// usage-limit error. Keeping this in a sidecar avoids overwriting concurrent
/// edits to `proxies.json` while still making the flag survive Edge restarts.
public struct FreeUsageLimitStore: Sendable {
    public static let fileName = "free-usage-limits.json"

    public let fileURL: URL

    public init(configDirectory: URL) {
        fileURL = configDirectory.appending(path: Self.fileName)
    }

    /// Applies only deadlines that are still in the future. Expired entries
    /// are left on disk as harmless history; they no longer affect routing.
    public func applying(to state: ProxyState, now: Double = Date().timeIntervalSince1970) -> ProxyState {
        let deadlines = readDeadlines()
        var result = state
        for index in result.proxies.indices {
            let deadline = deadlines[result.proxies[index].id]
            result.proxies[index].freeUsageLimitedUntil = deadline.flatMap { $0 > now ? $0 : nil }
        }
        return result
    }

    /// Extends (never shortens) an entry's quarantine deadline.
    @discardableResult
    public func flag(_ entryID: String, until deadline: Double) throws -> Double {
        guard !entryID.isEmpty, deadline.isFinite, deadline > 0 else {
            throw FreeUsageLimitStoreError.invalidDeadline
        }
        var deadlines = readDeadlines()
        let effectiveDeadline = max(deadlines[entryID] ?? 0, deadline)
        deadlines[entryID] = effectiveDeadline

        let manager = FileManager.default
        let directory = fileURL.deletingLastPathComponent()
        try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var data = try encoder.encode(deadlines)
        data.append(0x0A)
        try data.write(to: fileURL, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        return effectiveDeadline
    }

    public var modificationDate: Date? {
        (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.modificationDate]) as? Date
    }

    private func readDeadlines() -> [String: Double] {
        guard let data = try? Data(contentsOf: fileURL),
              let deadlines = try? JSONDecoder().decode([String: Double].self, from: data) else { return [:] }
        return deadlines.filter { !$0.key.isEmpty && $0.value.isFinite && $0.value > 0 }
    }
}

public enum FreeUsageLimitStoreError: Error, Equatable {
    case invalidDeadline
}
