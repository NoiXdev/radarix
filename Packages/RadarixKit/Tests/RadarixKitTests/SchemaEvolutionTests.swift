import Foundation
import Testing
@testable import RadarixKit

/// Files written by earlier versions must keep decoding when fields are added.
struct SchemaEvolutionTests {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: Data(json.utf8))
    }

    private func expectedAccount() -> AccountData {
        var a = AccountData(accountID: AccountID(rawValue: 42), login: "me")
        a.schemaVersion = 1
        a.watch.owners["acme"] = .all(excluded: [RepoID(rawValue: 7)])
        a.watch.owners["solo"] = .selected([RepoID(rawValue: 1)])
        a.watch.showArchived = true
        a.watch.notificationsOff = [RepoID(rawValue: 2)]
        let seen = Item.fixture(
            repo: 1, number: 1, kind: .pullRequest, title: "Seen PR", author: "alice", status: .merged,
            labels: [Label(name: "bug", colorHex: "d73a4a"), Label(name: "plain", colorHex: nil)],
            assignees: ["me"], requestedReviewers: ["bob"], commentCount: 4, createdAt: t0, updatedAt: t1,
            bodyExcerpt: "Excerpt")
        let new = Item.fixture(repo: 1, number: 2, title: "New issue", author: "dependabot[bot]", createdAt: t1, updatedAt: t2)
        a.repos[RepoID(rawValue: 1)] = RepoState(
            repo: .fixture(id: 1, owner: "solo", name: "tool"), baselineAt: t0, highWaterMark: t2,
            records: [
                1: ItemRecord(item: seen, attention: .seen, seenAt: t1, commentsAtSeen: 3),
                2: ItemRecord(item: new, attention: .new, seenAt: nil, commentsAtSeen: 0),
            ],
            lastFailure: "boom")
        return a
    }

    @Test func plan1FilesDecode() throws {
        let settings = try decode(AppSettings.self, fixtureJSON("plan1-settings"))
        var expectedSettings = AppSettings()
        expectedSettings.schemaVersion = 1
        expectedSettings.layout = .grouped
        expectedSettings.refreshInterval = 600
        expectedSettings.botDisplay = .grouped
        expectedSettings.notifyBots = true
        expectedSettings.notifyUpdated = true
        expectedSettings.openAtLogin = true
        expectedSettings.accountIDs = [AccountID(rawValue: 42)]
        #expect(settings == expectedSettings)
        #expect(settings.schemaVersion == 1)

        let account = try decode(AccountData.self, fixtureJSON("plan1-account"))
        #expect(account == expectedAccount())
        #expect(account.schemaVersion == 1)
    }

    @Test func checkForUpdatesDefaultsOn() throws {
        #expect(try decode(AppSettings.self, fixtureJSON("plan2-settings")).checkForUpdates)
        #expect(try decode(AppSettings.self, #"{"schemaVersion":3,"layout":"grouped"}"#).checkForUpdates)
        var off = AppSettings()
        off.checkForUpdates = false
        let data = try JSONEncoder().encode(off)
        #expect(try JSONDecoder().decode(AppSettings.self, from: data).checkForUpdates == false)
    }

    @Test func v2SettingsMapLastAccountToAccountList() throws {
        let settings = try decode(AppSettings.self, fixtureJSON("plan2-settings"))
        var expected = AppSettings()
        expected.schemaVersion = 2
        expected.layout = .grouped
        expected.refreshInterval = 600
        expected.botDisplay = .grouped
        expected.notifyBots = true
        expected.notifyUpdated = true
        expected.openAtLogin = true
        expected.accountIDs = [AccountID(rawValue: 42)]
        #expect(settings == expected)
    }

    @Test func plan1SettingsMapLastAccountToAccountList() throws {
        let settings = try decode(AppSettings.self, fixtureJSON("plan1-settings"))
        #expect(settings.accountIDs == [AccountID(rawValue: 42)])
        #expect(settings.schemaVersion == 1)
    }

    @Test func settingsWithoutAccountDecodeToEmptyList() throws {
        let settings = try decode(AppSettings.self, "{}")
        #expect(settings.accountIDs == [])
        #expect(settings.schemaVersion == 1)
    }

    @Test func settingsEncodeAccountIDsNotLastAccountID() throws {
        var settings = AppSettings()
        settings.accountIDs = [AccountID(rawValue: 1), AccountID(rawValue: 2)]
        let data = try JSONEncoder().encode(settings)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let ids = try #require(object["accountIDs"] as? [[String: Int]])
        #expect(ids == [["rawValue": 1], ["rawValue": 2]])
        #expect(object["lastAccountID"] == nil)
        #expect(object["schemaVersion"] as? Int == 6)
    }

    @Test func settingsFromOneZeroLoadWithFilterDefaults() throws {
        let settings = try decode(AppSettings.self, #"{"schemaVersion":3,"layout":"grouped","accountIDs":[{"rawValue":42}]}"#)
        #expect(settings.filter == FilterSet())
        #expect(settings.showsBots == false)
        #expect(settings.groupAllByRepo == false)
        #expect(settings.accountIDs == [AccountID(rawValue: 42)])
    }

    @Test func filterRoundTripsThroughSettings() throws {
        var settings = AppSettings()
        settings.filter.assignedToMe = true
        settings.filter.new = false
        settings.showsBots = true
        settings.groupAllByRepo = true
        let data = try JSONEncoder().encode(settings)
        #expect(try JSONDecoder().decode(AppSettings.self, from: data) == settings)
    }

    @Test func settingsFromOneOneLoadWithNewDefaults() throws {
        let settings = try decode(AppSettings.self, #"{"schemaVersion":4,"layout":"grouped","accountIDs":[{"rawValue":42}]}"#)
        #expect(settings.descriptionPlacement == .window)
        #expect(settings.startInBackground == false)
        #expect(settings.menuBarOnlyWhenClosed == false)
        #expect(settings.layout == .grouped)
        #expect(settings.accountIDs == [AccountID(rawValue: 42)])
    }

    @Test func newSettingsRoundTrip() throws {
        var settings = AppSettings()
        settings.descriptionPlacement = .sidebar
        settings.startInBackground = true
        settings.menuBarOnlyWhenClosed = true
        let data = try JSONEncoder().encode(settings)
        #expect(try JSONDecoder().decode(AppSettings.self, from: data) == settings)
    }

    @Test func unknownDescriptionPlacementFallsBackToWindow() throws {
        let settings = try decode(AppSettings.self, #"{"schemaVersion":5,"layout":"grouped","descriptionPlacement":"popover","startInBackground":true,"accountIDs":[{"rawValue":42}]}"#)
        #expect(settings.descriptionPlacement == .window)
        #expect(settings.startInBackground)
        #expect(settings.layout == .grouped)
        #expect(settings.accountIDs == [AccountID(rawValue: 42)])
    }

    @Test func filterMissingAKeyKeepsTheOthers() throws {
        let filter = try decode(FilterSet.self, #"{"new":false,"issues":true}"#)
        var expected = FilterSet()
        expected.new = false
        expected.issues = true
        #expect(filter == expected)
        #expect(filter.updated)
        #expect(!filter.unassigned && !filter.assignedToMe && !filter.reviewRequested && !filter.pullRequests)
    }

    @Test func accountWithoutAvailableDecodesEmpty() throws {
        let account = try decode(AccountData.self, fixtureJSON("plan1-account"))
        #expect(account.available == [:])
    }

    @Test func accountV3DecodesWithoutStats() throws {
        let account = try decode(AccountData.self, fixtureJSON("plan1-account"))
        #expect(account.stats == [:])
    }

    @Test func emptyObjectsUseDefaults() throws {
        var expected = AppSettings()
        expected.schemaVersion = 1
        #expect(try decode(AppSettings.self, "{}") == expected)
        #expect(try decode(WatchConfig.self, "{}") == WatchConfig())
    }

    @Test func accountWithOnlyRequiredKeysDecodes() throws {
        let account = try decode(AccountData.self, #"{"accountID":{"rawValue":5},"login":"x"}"#)
        #expect(account.accountID == AccountID(rawValue: 5))
        #expect(account.login == "x")
        #expect(account.watch == WatchConfig())
        #expect(account.repos.isEmpty)
        #expect(account.schemaVersion == 1)
    }

    @Test func itemWithoutOptionalKeysDecodes() throws {
        let json = """
        {"key":{"number":3,"repo":{"rawValue":9}},"kind":"issue","title":"T","url":"https://github.com/o/r/issues/3",
         "author":{"isBot":false,"login":"a"},"createdAt":"2027-01-15T08:00:00Z","updatedAt":"2027-01-15T09:00:00Z"}
        """
        let item = try decode(Item.self, json)
        #expect(item.status == .open)
        #expect(!item.isDraft)
        #expect(item.labels.isEmpty)
        #expect(item.assignees.isEmpty)
        #expect(item.requestedReviewers.isEmpty)
        #expect(item.commentCount == 0)
        #expect(item.bodyExcerpt == "")
    }

    @Test func unknownKeysAreIgnored() throws {
        let settings = try decode(AppSettings.self, #"{"layout":"grouped","futureThing":{"a":1},"schemaVersion":3}"#)
        #expect(settings.layout == .grouped)
        #expect(settings.schemaVersion == 3)
        let account = try decode(AccountData.self, #"{"accountID":{"rawValue":5},"login":"x","extra":[1,2]}"#)
        #expect(account.login == "x")
    }

    @Test func savedFilesCarryCurrentVersion() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = FileStore(directory: dir)

        let settings = try decode(AppSettings.self, fixtureJSON("plan1-settings"))
        let account = try decode(AccountData.self, fixtureJSON("plan1-account"))
        try store.saveSettings(settings)
        try store.saveAccount(account)

        var reloadedSettings = try store.loadSettings()
        #expect(reloadedSettings.schemaVersion == 6)
        reloadedSettings.schemaVersion = 1
        #expect(reloadedSettings == settings)

        var reloadedAccount = try #require(try store.loadAccount(account.accountID))
        #expect(reloadedAccount.schemaVersion == 4)
        reloadedAccount.schemaVersion = 1
        #expect(reloadedAccount == account)
    }

    @Test func periodDefaultsTo30() throws {
        #expect(AppSettings().repoInfoPeriodDays == 30)
        #expect(try decode(AppSettings.self, fixtureJSON("plan2-settings")).repoInfoPeriodDays == 30)
    }

    @Test func periodDecodesTolerantly() throws {
        #expect(try decode(AppSettings.self, #"{"schemaVersion":6,"repoInfoPeriodDays":14}"#).repoInfoPeriodDays == 30)
        #expect(try decode(AppSettings.self, #"{"schemaVersion":6,"repoInfoPeriodDays":90}"#).repoInfoPeriodDays == 90)
        #expect(try decode(AppSettings.self, #"{"schemaVersion":6,"repoInfoPeriodDays":"x"}"#).repoInfoPeriodDays == 30)
    }

    @Test func periodRoundTrips() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = FileStore(directory: dir)
        let controller = await MainActor.run {
            let controller = RadarixController(
                store: store, credentials: InMemoryCredentialStore(),
                makeAPI: { _ in StubGitHubAPI() }, oauthClientID: "client-id")
            controller.updateSettings { $0.repoInfoPeriodDays = 7 }
            return controller
        }
        _ = controller
        #expect(try store.loadSettings().repoInfoPeriodDays == 7)
    }
}
