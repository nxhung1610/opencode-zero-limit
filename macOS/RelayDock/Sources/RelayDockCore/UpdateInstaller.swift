import Darwin
import Foundation

/// One downloaded-and-verified update, ready to replace the running app.
public struct StagedUpdate: Equatable, Sendable {
    public var release: UpdateRelease
    public var stagedAppURL: URL

    public init(release: UpdateRelease, stagedAppURL: URL) {
        self.release = release
        self.stagedAppURL = stagedAppURL
    }
}

/// The arguments the GUI hands to the helper process that applies an update
/// after the GUI has quit.
public struct UpdateHelperRequest: Equatable, Sendable {
    public static let flag = "--apply-update"

    public var stagedAppURL: URL
    public var targetAppURL: URL
    public var parentPID: pid_t
    public var stagingRoot: URL
    public var statusFileURL: URL

    public init(
        stagedAppURL: URL,
        targetAppURL: URL,
        parentPID: pid_t,
        stagingRoot: URL,
        statusFileURL: URL
    ) {
        self.stagedAppURL = stagedAppURL
        self.targetAppURL = targetAppURL
        self.parentPID = parentPID
        self.stagingRoot = stagingRoot
        self.statusFileURL = statusFileURL
    }
}

/// Updates fail closed: nothing touches the installed app until the archive
/// hash, the bundle identity, and the code signature all check out.
public enum UpdateInstaller {
    public static let supportedBundleID = "com.nxhung.relaydock"
    public static let statusFileName = "update-status.txt"

    // MARK: - Preflight

    /// Reasons an in-place update is impossible, surfaced before anything is
    /// downloaded so the user learns the fix up front, not mid-install.
    public static func preflight(targetApp: URL) throws {
        guard targetApp.pathExtension == "app" else {
            throw UpdateError.unsupportedLocation(
                "Updates replace an installed RelayDock.app; this build runs outside an app bundle."
            )
        }
        guard !targetApp.path.contains("/AppTranslocation/") else {
            throw UpdateError.unsupportedLocation(
                "RelayDock is running from a read-only translocated copy. Move it to /Applications and relaunch, then update."
            )
        }
        let parent = targetApp.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: parent.path) else {
            throw UpdateError.unsupportedLocation(
                "The folder that contains RelayDock is not writable. Move the app to /Applications and try again."
            )
        }
    }

    // MARK: - Staging

    /// Verifies the downloaded zip against `SHA256SUMS` and unpacks a staged,
    /// validated copy of the app. `verifySignature` is injectable so tests can
    /// exercise the flow without building signed bundles.
    public static func stage(
        zipFileURL: URL,
        checksums: String,
        release: UpdateRelease,
        workingDirectory: URL,
        verifySignature: (URL) -> Bool = codesignVerifies
    ) throws -> StagedUpdate {
        guard let expected = ChecksumFile.parse(checksums)[UpdateRelease.zipAssetName] else {
            throw UpdateError.checksumsMissingEntry
        }
        let actual = try ChecksumFile.sha256Hex(ofFileAt: zipFileURL)
        guard actual == expected else {
            throw UpdateError.checksumMismatch(expected: expected, actual: actual)
        }

        let stagedRoot = workingDirectory.appending(path: "staged", directoryHint: .isDirectory)
        try? FileManager.default.removeItem(at: stagedRoot)
        try FileManager.default.createDirectory(at: stagedRoot, withIntermediateDirectories: true)
        guard runProcess("/usr/bin/ditto", ["-x", "-k", zipFileURL.path, stagedRoot.path]) else {
            throw UpdateError.unzipFailed
        }

        let stagedApp = stagedRoot.appending(path: "RelayDock.app", directoryHint: .isDirectory)
        try validate(stagedApp: stagedApp, expectedVersion: release.version, verifySignature: verifySignature)
        return StagedUpdate(release: release, stagedAppURL: stagedApp)
    }

    /// What a downloaded bundle must prove before it may replace the running
    /// app: same identity, same version as the release, a runnable executable,
    /// and a strict-valid code signature (fail closed).
    public static func validate(
        stagedApp: URL,
        expectedVersion: SemanticVersion,
        expectedBundleID: String = UpdateInstaller.supportedBundleID,
        verifySignature: (URL) -> Bool = codesignVerifies
    ) throws {
        let plistURL = stagedApp.appending(path: "Contents/Info.plist")
        guard let data = try? Data(contentsOf: plistURL),
              let object = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let plist = object as? [String: Any] else {
            throw UpdateError.invalidBundle("The archive did not contain a RelayDock.app bundle.")
        }
        guard plist["CFBundleIdentifier"] as? String == expectedBundleID else {
            throw UpdateError.invalidBundle("The bundle identifier does not match RelayDock.")
        }
        guard let versionString = plist["CFBundleShortVersionString"] as? String,
              SemanticVersion(tag: versionString) == expectedVersion else {
            throw UpdateError.invalidBundle("The bundle version does not match the release.")
        }
        guard let executable = plist["CFBundleExecutable"] as? String else {
            throw UpdateError.invalidBundle("The bundle is missing CFBundleExecutable.")
        }
        let executableURL = stagedApp.appending(path: "Contents/MacOS/\(executable)")
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw UpdateError.invalidBundle("The app executable is missing.")
        }
        guard verifySignature(stagedApp) else {
            throw UpdateError.invalidBundle("The code signature did not verify.")
        }
    }

    public static func codesignVerifies(_ app: URL) -> Bool {
        runProcess("/usr/bin/codesign", ["--verify", "--strict", app.path])
    }

    // MARK: - Apply (helper mode)

    /// Parses `RelayDock --apply-update <staged> <target> <pid> <stagingRoot> <statusFile>`.
    public static func helperRequest(from arguments: [String]) -> UpdateHelperRequest? {
        guard arguments.count == 7, arguments[1] == UpdateHelperRequest.flag,
              let parentPID = pid_t(arguments[4]) else {
            return nil
        }
        return UpdateHelperRequest(
            stagedAppURL: URL(fileURLWithPath: arguments[2]),
            targetAppURL: URL(fileURLWithPath: arguments[3]),
            parentPID: parentPID,
            stagingRoot: URL(fileURLWithPath: arguments[5]),
            statusFileURL: URL(fileURLWithPath: arguments[6])
        )
    }

    /// Spawns the helper before the GUI quits. The helper keeps running from
    /// the inode of the old bundle even as the swap replaces it on disk.
    public static func spawnHelper(executableURL: URL, request: UpdateHelperRequest) throws {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = [
            UpdateHelperRequest.flag,
            request.stagedAppURL.path,
            request.targetAppURL.path,
            String(request.parentPID),
            request.stagingRoot.path,
            request.statusFileURL.path,
        ]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    /// Helper entry point: wait for the GUI to exit, swap the bundle, relaunch.
    /// The outcome lands in the status file for the next launch to surface.
    @discardableResult
    public static func runHelper(
        _ request: UpdateHelperRequest,
        relaunch: (URL) -> Void = openApp
    ) -> Int32 {
        guard waitForExit(of: request.parentPID, timeout: 30) else {
            writeStatus(
                "failed: RelayDock did not quit in time, so the update was left for the next attempt.",
                to: request.statusFileURL
            )
            return 2
        }
        do {
            try apply(
                stagedApp: request.stagedAppURL,
                targetApp: request.targetAppURL,
                stagingRoot: request.stagingRoot
            )
        } catch {
            let message = (error as? UpdateError)?.errorDescription ?? error.localizedDescription
            writeStatus("failed: \(message)", to: request.statusFileURL)
            return 1
        }
        writeStatus("ok", to: request.statusFileURL)
        relaunch(request.targetAppURL)
        return 0
    }

    /// The swap: copy the staged bundle next to the target (covers cross-volume
    /// setups), then rename old aside and new in. Renames are atomic, and every
    /// failure path leaves a launchable app in place.
    public static func apply(stagedApp: URL, targetApp: URL, stagingRoot: URL) throws {
        let manager = FileManager.default
        let parent = targetApp.deletingLastPathComponent()
        let token = String(UUID().uuidString.prefix(8))
        let incoming = parent.appending(path: ".relaydock-incoming-\(token)", directoryHint: .isDirectory)
        let backup = parent.appending(path: ".relaydock-backup-\(token)", directoryHint: .isDirectory)

        try? manager.removeItem(at: incoming)
        guard runProcess("/usr/bin/ditto", [stagedApp.path, incoming.path]) else {
            throw UpdateError.installFailed("The staged app could not be copied next to \(targetApp.path).")
        }
        do {
            try manager.moveItem(at: targetApp, to: backup)
        } catch {
            try? manager.removeItem(at: incoming)
            throw UpdateError.targetNotWritable
        }
        do {
            try manager.moveItem(at: incoming, to: targetApp)
        } catch {
            try? manager.moveItem(at: backup, to: targetApp)
            try? manager.removeItem(at: incoming)
            throw UpdateError.installFailed("The new build could not be moved into place.")
        }
        try? manager.removeItem(at: backup)
        try? manager.removeItem(at: stagingRoot)
    }

    public static func openApp(_ app: URL) {
        _ = runProcess("/usr/bin/open", ["-n", app.path])
    }

    /// True when the process exited before the timeout. A live parent aborts
    /// the update rather than swapping the bundle under a still-running app.
    @discardableResult
    static func waitForExit(of pid: pid_t, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !processIsRunning(pid) {
                return true
            }
            usleep(100_000)
        }
        return !processIsRunning(pid)
    }

    /// `kill(pid, 0)` probes existence; `ESRCH` is the only "it is gone".
    static func processIsRunning(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0 || errno != ESRCH
    }

    static func writeStatus(_ text: String, to url: URL) {
        try? (text + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    @discardableResult
    static func runProcess(_ tool: String, _ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return false
        }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}
