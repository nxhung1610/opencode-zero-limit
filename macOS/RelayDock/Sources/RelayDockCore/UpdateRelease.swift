import Foundation

/// The subset of a GitHub release payload the updater understands: the
/// version, the two assets the app needs, and the human-facing page.
public struct UpdateRelease: Equatable, Sendable {
    public static let zipAssetName = "RelayDock.app.zip"
    public static let checksumsAssetName = "SHA256SUMS"

    public var version: SemanticVersion
    public var tagName: String
    public var zipURL: URL
    public var checksumsURL: URL
    public var releasePageURL: URL

    public init(
        version: SemanticVersion,
        tagName: String,
        zipURL: URL,
        checksumsURL: URL,
        releasePageURL: URL
    ) {
        self.version = version
        self.tagName = tagName
        self.zipURL = zipURL
        self.checksumsURL = checksumsURL
        self.releasePageURL = releasePageURL
    }
}

/// Parsing for the Releases API payload (`GET /repos/…/releases/latest`).
public enum UpdateFeed {
    /// `RELAYDOCK_UPDATE_FEED` overrides the endpoint for dry runs and tests.
    public static func defaultFeedURL(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let override = environment["RELAYDOCK_UPDATE_FEED"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty,
           let url = URL(string: override) {
            return url
        }
        return URL(string: "https://api.github.com/repos/nxhung1610/relaydock/releases/latest")!
    }

    /// Returns nil when the payload is not a complete, comparable release.
    public static func parseLatest(_ data: Data) -> UpdateRelease? {
        struct Payload: Decodable {
            struct Asset: Decodable {
                var name: String
                var browserDownloadURL: String

                enum CodingKeys: String, CodingKey {
                    case name
                    case browserDownloadURL = "browser_download_url"
                }
            }

            var tagName: String
            var htmlURL: String
            var assets: [Asset]

            enum CodingKeys: String, CodingKey {
                case tagName = "tag_name"
                case htmlURL = "html_url"
                case assets
            }
        }

        guard let payload = try? JSONDecoder().decode(Payload.self, from: data),
              let version = SemanticVersion(tag: payload.tagName),
              let zip = payload.assets.first(where: { $0.name == UpdateRelease.zipAssetName }),
              let checksums = payload.assets.first(where: { $0.name == UpdateRelease.checksumsAssetName }),
              let zipURL = URL(string: zip.browserDownloadURL),
              let checksumsURL = URL(string: checksums.browserDownloadURL),
              let pageURL = URL(string: payload.htmlURL) else {
            return nil
        }
        return UpdateRelease(
            version: version,
            tagName: payload.tagName,
            zipURL: zipURL,
            checksumsURL: checksumsURL,
            releasePageURL: pageURL
        )
    }
}
