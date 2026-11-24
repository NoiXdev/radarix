import Foundation
import OSLog

/// JSON persistence: `settings.json`, `widget-snapshot.json` and `accounts/<accountID>.json` below one directory.
public final class FileStore: @unchecked Sendable {
    private let directory: URL
    private let fileManager = FileManager.default

    public init(directory: URL) {
        self.directory = directory
    }

    /// The shared app group directory when this process may write there, otherwise
    /// `~/Library/Application Support/Radarix`. An ad-hoc signed build is denied the
    /// group container, so it falls back (the widget then sees no snapshot).
    public static func defaultDirectory(appGroup: String) -> URL {
        let container = appGroup.isEmpty
            ? nil
            : FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
        return resolveDirectory(
            groupContainer: container,
            fallbackBase: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0],
            canWrite: canWrite)
    }

    static func resolveDirectory(groupContainer: URL?, fallbackBase: URL, canWrite: (URL) -> Bool) -> URL {
        if let groupContainer {
            let shared = groupContainer
                .appending(path: "Library/Application Support", directoryHint: .isDirectory)
                .appending(path: "Radarix", directoryHint: .isDirectory)
            if canWrite(shared) { return shared }
            log.notice("App group container is not writable; using Application Support")
        }
        return fallbackBase.appending(path: "Radarix", directoryHint: .isDirectory)
    }

    /// Creates `directory` if needed and writes and removes a probe file in it.
    static func canWrite(_ directory: URL) -> Bool {
        let fm = FileManager.default
        let probe = directory.appending(path: ".write-probe-\(UUID().uuidString)")
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data().write(to: probe)
            try fm.removeItem(at: probe)
            return true
        } catch {
            return false
        }
    }

    private static let log = Logger(subsystem: "dev.noix.radarix", category: "store")

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

    /// Nil when the file is missing.
    public func loadSnapshot() throws -> WidgetSnapshot? {
        try read(WidgetSnapshot.self, from: snapshotURL)
    }

    public func saveSnapshot(_ s: WidgetSnapshot) throws {
        try write(s, to: snapshotURL)
    }

    /// Does nothing when the file is missing.
    public func removeSnapshot() throws {
        guard fileManager.fileExists(atPath: snapshotURL.path) else { return }
        try fileManager.removeItem(at: snapshotURL)
    }

    public func resetAll() throws {
        guard fileManager.fileExists(atPath: directory.path) else { return }
        try fileManager.removeItem(at: directory)
    }

    private var settingsURL: URL { directory.appending(path: "settings.json") }
    private var snapshotURL: URL { directory.appending(path: "widget-snapshot.json") }

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
