import Foundation

/// Every failure the updater can report, with copy written for the panel.
public enum UpdateError: Error, Equatable, LocalizedError, Sendable {
    case requestFailed(String)
    case releaseUnavailable(String)
    case checksumsMissingEntry
    case checksumMismatch(expected: String, actual: String)
    case unzipFailed
    case invalidBundle(String)
    case unsupportedLocation(String)
    case targetNotWritable
    case installFailed(String)

    public var errorDescription: String? {
        switch self {
        case .requestFailed(let detail),
             .releaseUnavailable(let detail),
             .invalidBundle(let detail),
             .unsupportedLocation(let detail),
             .installFailed(let detail):
            return detail
        case .checksumsMissingEntry:
            return "SHA256SUMS does not list RelayDock.app.zip."
        case .checksumMismatch:
            return "The downloaded archive failed its SHA-256 check; nothing was installed."
        case .unzipFailed:
            return "The downloaded archive could not be unpacked."
        case .targetNotWritable:
            return "RelayDock could not replace the installed app (no write access to its folder)."
        }
    }
}
