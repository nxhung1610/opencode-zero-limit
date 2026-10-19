import Foundation

/// Networking for the updater. Update traffic never goes through system
/// proxies or Edge: it is control-plane, has to work while Edge is down, and
/// must not leak into the user's proxy path.
public enum UpdateClient {
    private static let userAgent = "RelayDock-updater/1"

    /// `GET /releases/latest`; throws `UpdateError` with panel-ready copy.
    public static func fetchLatestRelease(
        feedURL: URL? = nil,
        timeout: TimeInterval = 10
    ) async throws -> UpdateRelease {
        let url = feedURL ?? UpdateFeed.defaultFeedURL()
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        let (data, response) = try await send(request, timeout: timeout)
        guard let http = response as? HTTPURLResponse else {
            throw UpdateError.requestFailed("GitHub did not answer with an HTTP response.")
        }
        switch http.statusCode {
        case 200..<300:
            guard let release = UpdateFeed.parseLatest(data) else {
                throw UpdateError.releaseUnavailable(
                    "The latest release is missing RelayDock.app.zip or SHA256SUMS."
                )
            }
            return release
        case 404:
            throw UpdateError.releaseUnavailable("The repository has no published release yet.")
        default:
            throw UpdateError.requestFailed("GitHub answered HTTP \(http.statusCode).")
        }
    }

    /// Downloads a release asset to `destination`, replacing any existing file.
    public static func download(
        _ url: URL,
        to destination: URL,
        timeout: TimeInterval = 300
    ) async throws {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        let session = makeSession(timeout: timeout)
        defer { session.finishTasksAndInvalidate() }
        let temporaryURL: URL
        let response: URLResponse
        do {
            (temporaryURL, response) = try await session.download(for: request)
        } catch {
            throw UpdateError.requestFailed("The download failed: \(error.localizedDescription)")
        }
        let http = response as? HTTPURLResponse
        guard let http, (200..<300).contains(http.statusCode) else {
            throw UpdateError.requestFailed("The download failed with HTTP \(http?.statusCode ?? 0).")
        }

        let manager = FileManager.default
        try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? manager.removeItem(at: destination)
        do {
            try manager.moveItem(at: temporaryURL, to: destination)
        } catch {
            try manager.copyItem(at: temporaryURL, to: destination)
        }
    }

    /// Fetches a text asset (used for `SHA256SUMS`).
    public static func checksumsText(from url: URL, timeout: TimeInterval = 30) async throws -> String {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        let (data, response) = try await send(request, timeout: timeout)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let text = String(data: data, encoding: .utf8) else {
            throw UpdateError.requestFailed("SHA256SUMS could not be fetched.")
        }
        return text
    }

    /// The whole download-and-verify pipeline for one release: checksums,
    /// archive, hash check, unpack, bundle validation.
    public static func prepare(release: UpdateRelease, updatesRoot: URL) async throws -> StagedUpdate {
        let working = updatesRoot.appending(path: release.version.description, directoryHint: .isDirectory)
        try? FileManager.default.removeItem(at: working)
        try FileManager.default.createDirectory(at: working, withIntermediateDirectories: true)

        let checksums = try await checksumsText(from: release.checksumsURL)
        let zipURL = working.appending(path: UpdateRelease.zipAssetName)
        try await download(release.zipURL, to: zipURL)
        return try UpdateInstaller.stage(
            zipFileURL: zipURL,
            checksums: checksums,
            release: release,
            workingDirectory: working
        )
    }

    private static func makeSession(timeout: TimeInterval) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        // An empty proxy dictionary opts out of the system settings; nil
        // would inherit them.
        configuration.connectionProxyDictionary = [:]
        return URLSession(configuration: configuration)
    }

    private static func send(_ request: URLRequest, timeout: TimeInterval) async throws -> (Data, URLResponse) {
        let session = makeSession(timeout: timeout)
        defer { session.finishTasksAndInvalidate() }
        do {
            return try await session.data(for: request)
        } catch {
            throw UpdateError.requestFailed("GitHub is unreachable: \(error.localizedDescription)")
        }
    }
}
