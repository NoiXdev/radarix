import Foundation

/// JSON persistence: `settings.json` and `accounts/<accountID>.json` below one directory.
public final class FileStore: @unchecked Sendable {
    private let directory: URL
    private let fileManager = FileManager.default

    public init(directory: URL) {
        self.directory = directory
    }

    public static func defaultDirectory(appGroup: String) -> URL {
        let base: URL
        if !appGroup.isEmpty, let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) {
            base = container.appending(path: "Library/Application Support", directoryHint: .isDirectory)
        } else {
            base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        }
        return base.appending(path: "Radarix", directoryHint: .isDirectory)
    }

    public func loadSettings() throws -> AppSettings {
        try read(AppSettings.self, from: settingsURL) ?? AppSettings()
    }

    public func saveSettings(_ s: AppSettings) throws {
        try write(s, to: settingsURL)
    }

    public func loadAccount(_ id: AccountID) throws -> AccountData? {
        try read(AccountData.self, from: accountURL(id))
    }

    public func saveAccount(_ a: AccountData) throws {
        try write(a, to: accountURL(a.accountID))
    }

    public func resetAll() throws {
        guard fileManager.fileExists(atPath: directory.path) else { return }
        try fileManager.removeItem(at: directory)
    }

    private var settingsURL: URL { directory.appending(path: "settings.json") }

    private func accountURL(_ id: AccountID) -> URL {
        directory.appending(path: "accounts", directoryHint: .isDirectory).appending(path: "\(id.rawValue).json")
    }

    private func read<T: Decodable>(_ type: T.Type, from url: URL) throws -> T? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: Data(contentsOf: url))
    }

    private func write<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}
