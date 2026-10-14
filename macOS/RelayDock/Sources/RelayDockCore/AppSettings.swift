import Foundation

public struct AppSettings: Codable, Equatable, Sendable {
    public var autoRotate: Bool
    public var autoStart: Bool
    public var opencodeBin: String?
    public var theme: String

    public init(
        autoRotate: Bool = false,
        autoStart: Bool = true,
        opencodeBin: String? = nil,
        theme: String = "dark"
    ) {
        self.autoRotate = autoRotate
        self.autoStart = autoStart
        self.opencodeBin = opencodeBin
        self.theme = theme
    }

    public static let defaults = AppSettings()

    private struct AnyCodingKey: CodingKey {
        let stringValue: String
        let intValue: Int? = nil

        init(_ string: String) { stringValue = string }
        init?(stringValue: String) { self.init(stringValue) }
        init?(intValue: Int) { return nil }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        autoRotate = try container.decodeIfPresent(Bool.self, forKey: AnyCodingKey("autoRotate"))
            ?? container.decodeIfPresent(Bool.self, forKey: AnyCodingKey("auto_rotate"))
            ?? Self.defaults.autoRotate
        autoStart = try container.decodeIfPresent(Bool.self, forKey: AnyCodingKey("autoStart"))
            ?? container.decodeIfPresent(Bool.self, forKey: AnyCodingKey("auto_start"))
            ?? Self.defaults.autoStart
        opencodeBin = try container.decodeIfPresent(String.self, forKey: AnyCodingKey("opencodeBin"))
            ?? container.decodeIfPresent(String.self, forKey: AnyCodingKey("opencode_bin"))
        theme = try container.decodeIfPresent(String.self, forKey: AnyCodingKey("theme")) ?? Self.defaults.theme
    }
}

public struct SettingsStore: Sendable {
    public static let legacyNamespace = "com.nxhung.opencodezerolimit"

    public let fileURL: URL

    public init(configDirectory: URL? = nil, environment: [String: String] = ProcessInfo.processInfo.environment) {
        let directory: URL
        if let configDirectory {
            directory = configDirectory
        } else if let override = environment["RELAYDOCK_CONFIG_DIR"], !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            directory = URL(fileURLWithPath: override, isDirectory: true).standardizedFileURL
        } else {
            let homePath = environment["HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines)
            let home = homePath.flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
                ?? FileManager.default.homeDirectoryForCurrentUser
            directory = home
                .appending(path: "Library/Application Support", directoryHint: .isDirectory)
                .appending(path: Self.legacyNamespace, directoryHint: .isDirectory)
        }
        fileURL = directory.appending(path: "settings.json")
    }

    public func load() -> AppSettings {
        guard let data = try? Data(contentsOf: fileURL) else { return .defaults }
        return (try? JSONDecoder().decode(AppSettings.self, from: data)) ?? .defaults
    }

    public func save(_ settings: AppSettings) throws {
        let manager = FileManager.default
        let directory = fileURL.deletingLastPathComponent()
        try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)

        if let currentData = try? Data(contentsOf: fileURL), (try? JSONDecoder().decode(AppSettings.self, from: currentData)) == nil {
            let timestamp = Int(Date().timeIntervalSince1970 * 1_000)
            let backup = URL(fileURLWithPath: "\(fileURL.path).corrupt-\(timestamp)")
            try manager.moveItem(at: fileURL, to: backup)
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var data = try encoder.encode(settings)
        data.append(0x0A)
        try data.write(to: fileURL, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}
