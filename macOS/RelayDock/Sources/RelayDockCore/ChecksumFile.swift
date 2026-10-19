import CryptoKit
import Foundation

/// `shasum -a 256` output (`<hex>␠␠<name>`) and file hashing for the updater.
public enum ChecksumFile {
    /// Line format produced by `shasum -a 256`: a 64-hex digest, two spaces,
    /// then the file name (a leading `*` marks binary mode). Unusable lines
    /// are skipped rather than failing the whole file.
    public static func parse(_ text: String) -> [String: String] {
        var checksums: [String: String] = [:]
        for rawLine in text.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count >= 2 else { continue }
            let digest = String(parts[0]).lowercased()
            var name = String(parts[1])
            if name.hasPrefix("*") {
                name.removeFirst()
            }
            guard digest.count == 64, digest.allSatisfy(\.isHexDigit), !name.isEmpty else { continue }
            checksums[name] = digest
        }
        return checksums
    }

    /// Streaming SHA-256 so a download never has to fit in memory twice.
    public static func sha256Hex(ofFileAt url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
