import Foundation
import Testing
@testable import RadarixKit

struct FileStoreTests {
    private func makeDirectory() -> URL {
        FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    }

    @Test func settingsDefaultsWhenFileMissing() throws {
        let dir = makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let s = try FileStore(directory: dir).loadSettings()
        #expect(s == AppSettings())
        #expect(s.layout == .sidebar)
        #expect(s.refreshInterval == 300)
        #expect(s.botDisplay == .badge)
        #expect(!s.notifyBots && !s.notifyUpdated && !s.openAtLogin)
        #expect(s.lastAccountID == nil)
        #expect(AppSettings.refreshIntervals == [120, 300, 600, 900, 1800])
    }

    @Test func settingsRoundTrip() throws {
        let dir = makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = FileStore(directory: dir)
        var s = AppSettings()
        s.layout = .grouped
        s.refreshInterval = 600
        s.botDisplay = .hidden
        s.notifyBots = true
        s.lastAccountID = AccountID(rawValue: 7)
        try store.saveSettings(s)
        #expect(try store.loadSettings() == s)
        #expect(FileManager.default.fileExists(atPath: dir.appending(path: "settings.json").path))
    }

    @Test func accountRoundTripsAndIsKeyedByID() throws {
        let dir = makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = FileStore(directory: dir)
        let repo = RepoRef.fixture(id: 1)
        var a = AccountData(accountID: AccountID(rawValue: 42), login: "alice")
        a.watch.owners["o"] = .all(excluded: [RepoID(rawValue: 9)])
        a.watch.owners["p"] = .selected([RepoID(rawValue: 3)])
        a.watch.showArchived = true
        a.watch.notificationsOff = [RepoID(rawValue: 1)]
        a.repos[repo.id] = RepoState(
            repo: repo, baselineAt: t0, highWaterMark: t1,
            records: [5: ItemRecord(item: .fixture(number: 5), attention: .new, seenAt: t2, commentsAtSeen: 1)],
            lastFailure: "boom")
        try store.saveAccount(a)

        #expect(FileManager.default.fileExists(atPath: dir.appending(path: "accounts/42.json").path))
        #expect(try store.loadAccount(AccountID(rawValue: 42)) == a)
        #expect(try store.loadAccount(AccountID(rawValue: 43)) == nil)
    }

    @Test func corruptFilesThrow() throws {
        let dir = makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = FileStore(directory: dir)
        try FileManager.default.createDirectory(at: dir.appending(path: "accounts"), withIntermediateDirectories: true)
        try Data("nope".utf8).write(to: dir.appending(path: "settings.json"))
        try Data("nope".utf8).write(to: dir.appending(path: "accounts/1.json"))
        #expect(throws: (any Error).self) { try store.loadSettings() }
        #expect(throws: (any Error).self) { try store.loadAccount(AccountID(rawValue: 1)) }
    }

    @Test func resetAllRemovesEverything() throws {
        let dir = makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = FileStore(directory: dir)
        try store.saveSettings(AppSettings())
        try store.saveAccount(AccountData(accountID: AccountID(rawValue: 1), login: "a"))
        try store.resetAll()
        #expect(try store.loadAccount(AccountID(rawValue: 1)) == nil)
        #expect(try store.loadSettings() == AppSettings())
        #expect(!FileManager.default.fileExists(atPath: dir.appending(path: "settings.json").path))
    }

    @Test func snapshotRoundTripsAndRemoves() throws {
        let dir = makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = FileStore(directory: dir)
        #expect(try store.loadSnapshot() == nil)
        try store.removeSnapshot()

        let snapshot = WidgetSnapshot(status: .needsReauth, login: "me", syncedAt: t1, repos: [
            WidgetSnapshot.RepoEntry(id: RepoID(rawValue: 1), owner: "o", name: "r", newCount: 1, updatedCount: 0, items: [
                WidgetSnapshot.ItemEntry(
                    key: ItemKey(repo: RepoID(rawValue: 1), number: 3), kind: .issue, title: "T",
                    attention: .new, updatedAt: t0, isDraft: false, botName: nil),
            ]),
        ])
        try store.saveSnapshot(snapshot)
        #expect(FileManager.default.fileExists(atPath: dir.appending(path: "widget-snapshot.json").path))
        #expect(try store.loadSnapshot() == snapshot)

        try store.removeSnapshot()
        #expect(try store.loadSnapshot() == nil)
        #expect(!FileManager.default.fileExists(atPath: dir.appending(path: "widget-snapshot.json").path))
    }

    @Test func defaultDirectoryEndsInRadarix() {
        #expect(FileStore.defaultDirectory(appGroup: "").lastPathComponent == "Radarix")
    }
}
