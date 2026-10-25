import Foundation
import RelayDockCore
import Testing

@testable import RelayDockApp

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false

    func set() {
        lock.lock()
        flag = true
        lock.unlock()
    }

    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return flag
    }
}

private final class ValueBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T?

    func set(_ value: T) {
        lock.lock()
        stored = value
        lock.unlock()
    }

    var value: T? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

@MainActor
@Suite struct UpdateModelTests {
    // MARK: - Fixtures

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "relaydock-update-model-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeRelease(_ version: String) -> UpdateRelease {
        UpdateRelease(
            version: SemanticVersion(tag: version)!,
            tagName: "v\(version)",
            zipURL: URL(string: "https://example.com/RelayDock.app.zip")!,
            checksumsURL: URL(string: "https://example.com/SHA256SUMS")!,
            releasePageURL: URL(string: "https://example.com/releases/v\(version)")!
        )
    }

    private func makeDefaults() -> UserDefaults {
        let name = "relaydock-update-model-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private func makeModel(
        root: URL,
        defaults: UserDefaults,
        fetch: @escaping UpdateModel.ReleaseFetcher,
        prepare: UpdateModel.Preparer? = nil,
        spawn: @escaping UpdateModel.HelperSpawner = { _, _, _, _ in },
        terminate: @escaping () -> Void = {}
    ) -> UpdateModel {
        UpdateModel(
            configDirectory: root,
            targetAppURL: root.appending(path: "RelayDock.app", directoryHint: .isDirectory),
            currentVersion: SemanticVersion(major: 0, minor: 1, patch: 0),
            defaults: defaults,
            upToDateResetDelay: .milliseconds(120),
            fetchRelease: fetch,
            prepare: prepare ?? { release, _ in
                StagedUpdate(
                    release: release,
                    stagedAppURL: root.appending(path: "updates/0.2.0/staged/RelayDock.app", directoryHint: .isDirectory)
                )
            },
            spawnHelper: spawn,
            terminate: terminate
        )
    }

    // MARK: - Tests

    @Test func anAvailableUpdateStagesAndRestartsThroughTheHelper() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let release = makeRelease("0.2.0")

        let spawnBox = ValueBox<(StagedUpdate, URL, URL, URL)>()
        let terminated = Flag()
        let model = makeModel(
            root: root,
            defaults: makeDefaults(),
            fetch: { release },
            spawn: { staged, updatesRoot, targetApp, statusFile in
                spawnBox.set((staged, updatesRoot, targetApp, statusFile))
            },
            terminate: { terminated.set() }
        )

        #expect(model.versionDisplayText == "v0.1.0")

        await model.check(userInitiated: true)
        #expect(model.phase == .available(release))

        await model.update()
        #expect(model.phase == .ready(release))

        model.restartToUpdate()
        #expect(terminated.isSet)
        let captured = spawnBox.value
        #expect(captured?.0.release == release)
        #expect(captured?.1.lastPathComponent == "updates")
        #expect(captured?.2.lastPathComponent == "RelayDock.app")
        #expect(captured?.3.lastPathComponent == UpdateInstaller.statusFileName)
    }

    @Test func anUpToDateCheckQuietlyResets() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let release = makeRelease("0.1.0")
        let model = makeModel(root: root, defaults: makeDefaults(), fetch: { release })

        await model.check(userInitiated: true)
        #expect(model.phase == .upToDate)

        // Await the scheduled task itself. On a busy CI main actor, a wall-clock
        // polling deadline can expire before the reset task gets executor time.
        await model.waitForUpToDateResetForFixtures()
        #expect(model.phase == .idle)
    }

    @Test func autoCheckRunsAtMostOncePerDay() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let release = makeRelease("0.2.0")
        let calls = Counter()
        let defaults = makeDefaults()
        let model = makeModel(
            root: root,
            defaults: defaults,
            fetch: {
                calls.increment()
                return release
            }
        )

        await model.autoCheckIfDue()
        #expect(calls.value == 1)
        #expect(model.phase == .available(release))

        // A second appearance within the day is throttled and stays quiet.
        model.applyPhaseForFixtures(.idle)
        await model.autoCheckIfDue()
        #expect(calls.value == 1)

        // A fresh day checks again.
        defaults.removeObject(forKey: "RelayDockUpdateLastCheckedAt")
        await model.autoCheckIfDue()
        #expect(calls.value == 2)
    }

    @Test func manualFailuresSpeakAndAutomaticOnesStayQuiet() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let manual = makeModel(
            root: root,
            defaults: makeDefaults(),
            fetch: { throw UpdateError.requestFailed("GitHub is unreachable.") }
        )
        await manual.check(userInitiated: true)
        #expect(manual.phase == .failed("GitHub is unreachable."))

        let automatic = makeModel(
            root: root,
            defaults: makeDefaults(),
            fetch: { throw UpdateError.requestFailed("GitHub is unreachable.") }
        )
        await automatic.autoCheckIfDue()
        #expect(automatic.phase == .idle)
    }

    @Test func aFailedApplyFromLastSessionIsShownOnce() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let statusFile = root.appending(path: UpdateInstaller.statusFileName)
        try Data("failed: The folder could not be written.\n".utf8).write(to: statusFile)

        let model = makeModel(
            root: root,
            defaults: makeDefaults(),
            fetch: { throw UpdateError.requestFailed("x") }
        )
        #expect(model.phase == .failed("The folder could not be written."))
        #expect(!FileManager.default.fileExists(atPath: statusFile.path))

        let second = makeModel(
            root: root,
            defaults: makeDefaults(),
            fetch: { throw UpdateError.requestFailed("x") }
        )
        #expect(second.phase == .idle)
    }

    @Test func updatingRefusesToTouchSomethingThatIsNotAnAppBundle() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let release = makeRelease("0.2.0")

        let model = UpdateModel(
            configDirectory: root,
            targetAppURL: root,
            currentVersion: SemanticVersion(major: 0, minor: 1, patch: 0),
            defaults: makeDefaults(),
            fetchRelease: { release },
            prepare: { _, _ in throw UpdateError.installFailed("prepare should not run") },
            spawnHelper: { _, _, _, _ in },
            terminate: {}
        )

        await model.check(userInitiated: true)
        await model.update()
        guard case .failed(let message) = model.phase else {
            Issue.record("expected .failed, got \(model.phase)")
            return
        }
        #expect(message.contains("installed RelayDock.app"))
    }
}
