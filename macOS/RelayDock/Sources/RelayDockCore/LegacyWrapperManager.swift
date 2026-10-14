import Darwin
import Foundation

public enum LegacyWrapperStatus: Equatable, Sendable {
    case absent
    case managed(target: String)
    case unrelated
}

public enum LegacyWrapperError: LocalizedError, Equatable {
    case notManaged
    case removeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notManaged:
            "The OpenCode command path is not a RelayDock-managed symlink; it was left untouched."
        case .removeFailed(let message):
            "Could not remove the legacy RelayDock wrapper: \(message)"
        }
    }
}

/// Detects/removes only the old opt-in ~/.local/bin/opencode symlink created by RelayDock.
@MainActor
public final class LegacyWrapperManager {
    public let wrapperURL: URL
    private let fileManager: FileManager

    public init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser, fileManager: FileManager = .default) {
        self.wrapperURL = homeDirectory.appending(path: ".local/bin/opencode")
        self.fileManager = fileManager
    }

    public func status() -> LegacyWrapperStatus {
        var info = stat()
        let result = wrapperURL.path.withCString { lstat($0, &info) }
        guard result == 0 else { return errno == ENOENT ? .absent : .unrelated }
        guard (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFLNK),
              let target = try? fileManager.destinationOfSymbolicLink(atPath: wrapperURL.path) else {
            return .unrelated
        }

        let targetURL: URL
        if target.hasPrefix("/") {
            targetURL = URL(fileURLWithPath: target).standardizedFileURL
        } else {
            targetURL = wrapperURL.deletingLastPathComponent().appending(path: target).standardizedFileURL
        }
        guard isLegacyRelayDockTarget(targetURL) else { return .unrelated }
        return .managed(target: targetURL.path)
    }

    @discardableResult
    public func remove() throws -> LegacyWrapperStatus {
        guard case .managed = status() else { throw LegacyWrapperError.notManaged }
        let result = wrapperURL.path.withCString { unlink($0) }
        guard result == 0 else {
            throw LegacyWrapperError.removeFailed(String(cString: strerror(errno)))
        }
        return .absent
    }

    private func isLegacyRelayDockTarget(_ target: URL) -> Bool {
        guard target.lastPathComponent == "opencode-proxy.cjs",
              target.deletingLastPathComponent().lastPathComponent == "bin" else { return false }
        if fileManager.fileExists(atPath: target.path),
           let contents = try? String(contentsOf: target, encoding: .utf8) {
            return contents.contains("findRealOpenCodeBinary") && contents.contains("ProxyStore")
        }
        let projectName = target.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent.lowercased()
        return projectName.contains("relaydock")
    }
}
