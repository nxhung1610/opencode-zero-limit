import Foundation
import Testing
@testable import RelayDockCore

struct LegacyWrapperManagerTests {
    @Test @MainActor func removesOnlyTheRelayDockManagedSymlink() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "relaydock-wrapper-test-\(UUID().uuidString)", directoryHint: .isDirectory)
        let home = root.appending(path: "home", directoryHint: .isDirectory)
        let project = root.appending(path: "relaydock", directoryHint: .isDirectory)
        let target = project.appending(path: "bin/opencode-proxy.cjs")
        let link = home.appending(path: ".local/bin/opencode")
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("// findRealOpenCodeBinary and ProxyStore wrapper".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: target.path)
        defer { try? FileManager.default.removeItem(at: root) }

        let manager = LegacyWrapperManager(homeDirectory: home)
        #expect(manager.status() == .managed(target: target.path))

        let result = try manager.remove()

        #expect(result == .absent)
        #expect(manager.status() == .absent)
        #expect(FileManager.default.fileExists(atPath: target.path))
    }

    @Test @MainActor func leavesUnrelatedFilesAndSymlinksUntouched() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "relaydock-wrapper-other-\(UUID().uuidString)", directoryHint: .isDirectory)
        let home = root.appending(path: "home", directoryHint: .isDirectory)
        let link = home.appending(path: ".local/bin/opencode")
        let unrelated = root.appending(path: "installed/opencode")
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: unrelated.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh".utf8).write(to: unrelated)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: unrelated.path)
        defer { try? FileManager.default.removeItem(at: root) }

        let manager = LegacyWrapperManager(homeDirectory: home)
        #expect(manager.status() == .unrelated)
        #expect(throws: LegacyWrapperError.notManaged) { try manager.remove() }
        #expect(FileManager.default.fileExists(atPath: link.path))
        #expect(FileManager.default.fileExists(atPath: unrelated.path))
    }

    @Test @MainActor func reportsWhenNoLegacyWrapperExists() {
        let root = FileManager.default.temporaryDirectory.appending(path: "relaydock-wrapper-absent-\(UUID().uuidString)", directoryHint: .isDirectory)
        let manager = LegacyWrapperManager(homeDirectory: root)
        #expect(manager.status() == .absent)
        #expect(throws: LegacyWrapperError.notManaged) { try manager.remove() }
    }
}
