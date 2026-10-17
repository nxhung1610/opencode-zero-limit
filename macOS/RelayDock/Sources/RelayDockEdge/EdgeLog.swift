import Foundation

/// Appends to `edge.log` on a serial queue, so concurrent connection tasks
/// never interleave a line. Rotation truncates to the most recent half past
/// 512 KB: a resident daemon runs for weeks without unbounded growth.
/// Credentials are never logged — callers pass masked URLs.
final class EdgeLog: @unchecked Sendable {
    private let url: URL
    private let queue = DispatchQueue(label: "relaydock.edge.log")
    private let formatter: ISO8601DateFormatter

    private static let maximumBytes = 512 * 1024
    private static let keepBytes = 256 * 1024

    init(url: URL) {
        self.url = url
        formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }

    func info(_ message: String) { write(level: "info", message: message, synchronous: false) }
    func warn(_ message: String) { write(level: "warn", message: message, synchronous: false) }
    /// Errors write synchronously: they almost always precede an `exit()`, and
    /// an async write would race the process teardown.
    func error(_ message: String) { write(level: "error", message: message, synchronous: true) }

    /// Blocks until every queued line is on disk. Call before `exit()`.
    func flush() {
        queue.sync {}
    }

    private func write(level: String, message: String, synchronous: Bool) {
        let timestamp = formatter.string(from: Date())
        let emit = { [url] in
            Self.rotateIfNeeded(url: url)
            let line = Data("\(timestamp) [\(level)] \(message)\n".utf8)
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: line)
            } else {
                try? line.write(to: url, options: .atomic)
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            }
        }
        if synchronous {
            queue.sync(execute: emit)
        } else {
            queue.async(execute: emit)
        }
    }

    private static func rotateIfNeeded(url: URL) {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int,
              size > maximumBytes,
              let data = try? Data(contentsOf: url) else { return }
        let kept = data.suffix(keepBytes)
        try? Data(kept).write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
