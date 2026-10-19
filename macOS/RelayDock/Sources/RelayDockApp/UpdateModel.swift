import AppKit
import Foundation
import RelayDockCore

/// The app's update lifecycle: a quiet daily check, a one-click download, and
/// a helper process that swaps the bundle after the app quits.
@MainActor
final class UpdateModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case checking
        case upToDate
        case available(UpdateRelease)
        case downloading(UpdateRelease)
        case ready(UpdateRelease)
        case failed(String)
    }

    static let checkInterval: TimeInterval = 24 * 60 * 60
    private static let lastCheckKey = "RelayDockUpdateLastCheckedAt"

    typealias ReleaseFetcher = @Sendable () async throws -> UpdateRelease
    typealias Preparer = @Sendable (UpdateRelease, URL) async throws -> StagedUpdate
    typealias HelperSpawner = @Sendable (StagedUpdate, URL, URL, URL) throws -> Void

    @Published private(set) var phase: Phase = .idle

    /// The version this build reports; nil outside an app bundle (dev runs).
    let currentVersion: SemanticVersion?

    var versionDisplayText: String {
        currentVersion.map { "v\($0)" } ?? "dev"
    }

    private let targetAppURL: URL
    private let updatesRoot: URL
    private let statusFileURL: URL
    private let defaults: UserDefaults
    private let upToDateResetDelay: Duration
    private let fetchRelease: ReleaseFetcher
    private let prepare: Preparer
    private let spawnHelper: HelperSpawner
    private let terminate: () -> Void
    private var stagedUpdate: StagedUpdate?
    private var upToDateResetTask: Task<Void, Never>?

    init(
        configDirectory: URL,
        targetAppURL: URL = Bundle.main.bundleURL,
        currentVersion: SemanticVersion? = UpdateModel.bundleVersion(),
        defaults: UserDefaults = .standard,
        upToDateResetDelay: Duration = .seconds(4),
        fetchRelease: @escaping ReleaseFetcher = { try await UpdateClient.fetchLatestRelease() },
        prepare: @escaping Preparer = { release, updatesRoot in
            try await UpdateClient.prepare(release: release, updatesRoot: updatesRoot)
        },
        spawnHelper: @escaping HelperSpawner = { staged, updatesRoot, targetApp, statusFile in
            guard let executable = Bundle.main.executableURL else {
                throw UpdateError.installFailed("The running app has no executable path.")
            }
            try UpdateInstaller.spawnHelper(
                executableURL: executable,
                request: UpdateHelperRequest(
                    stagedAppURL: staged.stagedAppURL,
                    targetAppURL: targetApp,
                    parentPID: ProcessInfo.processInfo.processIdentifier,
                    stagingRoot: updatesRoot,
                    statusFileURL: statusFile
                )
            )
        },
        terminate: @escaping () -> Void = { NSApp.terminate(nil) }
    ) {
        self.targetAppURL = targetAppURL
        self.currentVersion = currentVersion
        self.defaults = defaults
        self.upToDateResetDelay = upToDateResetDelay
        self.fetchRelease = fetchRelease
        self.prepare = prepare
        self.spawnHelper = spawnHelper
        self.terminate = terminate
        self.updatesRoot = configDirectory.appending(path: "updates", directoryHint: .isDirectory)
        self.statusFileURL = configDirectory.appending(path: UpdateInstaller.statusFileName)

        // A fresh session starts clean: staging left behind by a quit without
        // applying is re-downloaded, and the helper's one-line outcome from a
        // quit-to-apply cycle is surfaced once.
        try? FileManager.default.removeItem(at: updatesRoot)
        consumeStatusFile()
    }

    /// The once-a-day quiet check, run when a surface appears. Manual checks
    /// ignore the throttle; automatic ones never speak unless there is news.
    func autoCheckIfDue() async {
        guard phase == .idle else { return }
        if let last = defaults.object(forKey: Self.lastCheckKey) as? Date,
           Date().timeIntervalSince(last) < Self.checkInterval {
            return
        }
        await check(userInitiated: false)
    }

    func check(userInitiated: Bool) async {
        switch phase {
        case .checking, .downloading, .ready:
            return
        default:
            break
        }
        guard let currentVersion else {
            if userInitiated {
                phase = .failed("This build has no bundle version, so updates are unavailable.")
            }
            return
        }

        phase = .checking
        defer { defaults.set(Date(), forKey: Self.lastCheckKey) }
        do {
            let release = try await fetchRelease()
            if release.version > currentVersion {
                phase = .available(release)
            } else {
                phase = .upToDate
                scheduleUpToDateReset()
            }
        } catch {
            phase = userInitiated ? .failed(Self.message(for: error)) : .idle
        }
    }

    /// The user pressed Update: preflight, then download + verify + stage.
    func update() async {
        guard case .available(let release) = phase else { return }
        do {
            try UpdateInstaller.preflight(targetApp: targetAppURL)
        } catch {
            phase = .failed(Self.message(for: error))
            return
        }

        phase = .downloading(release)
        do {
            let staged = try await prepare(release, updatesRoot)
            stagedUpdate = staged
            phase = .ready(release)
        } catch {
            phase = .failed(Self.message(for: error))
        }
    }

    /// Last step: spawn the swap helper, then quit. The helper waits for this
    /// process to exit, replaces the bundle, and relaunches the new build.
    func restartToUpdate() {
        guard case .ready = phase, let stagedUpdate else { return }
        do {
            try spawnHelper(stagedUpdate, updatesRoot, targetAppURL, statusFileURL)
        } catch {
            phase = .failed("RelayDock couldn't start its updater helper: \(error.localizedDescription)")
            return
        }
        terminate()
    }

    /// Test/fixture seam mirroring `ProxyAppModel.applyEdgePanelForFixtures`.
    func applyPhaseForFixtures(_ phase: Phase) {
        self.phase = phase
    }

    private func scheduleUpToDateReset() {
        upToDateResetTask?.cancel()
        upToDateResetTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: upToDateResetDelay)
            guard !Task.isCancelled else { return }
            if phase == .upToDate {
                phase = .idle
            }
        }
    }

    /// Reads the helper's one-line outcome file; a failure from the last
    /// quit-to-apply cycle is shown once, then cleared.
    private func consumeStatusFile() {
        guard let text = try? String(contentsOf: statusFileURL, encoding: .utf8) else { return }
        try? FileManager.default.removeItem(at: statusFileURL)
        let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty, message != "ok" else { return }
        let prefix = "failed: "
        phase = .failed(message.hasPrefix(prefix) ? String(message.dropFirst(prefix.count)) : message)
    }

    private static func message(for error: Error) -> String {
        (error as? UpdateError)?.errorDescription ?? error.localizedDescription
    }

    static func bundleVersion() -> SemanticVersion? {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String)
            .flatMap(SemanticVersion.init(tag:))
    }
}
