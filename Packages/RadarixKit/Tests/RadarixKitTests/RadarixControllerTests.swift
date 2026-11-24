import Foundation
import Synchronization
import Testing
@testable import RadarixKit

private let me = AccountID(rawValue: 42)
private let user = OwnerRef(login: "o", kind: .user)
private let repoA = RepoRef.fixture(id: 1, name: "a")
private let repoB = RepoRef.fixture(id: 2, name: "b")
/// Local clock, deliberately different from every server timestamp.
private let localNow = t0.addingTimeInterval(600)

private final class TestClock: Sendable {
    private let value: Mutex<Date>
    init(_ date: Date) { value = Mutex(date) }
    var now: Date {
        get { value.withLock { $0 } }
        set { value.withLock { $0 = newValue } }
    }
}

private final class TokenLog: Sendable {
    private let value = Mutex<[String]>([])
    var tokens: [String] { value.withLock { $0 } }
    func append(_ token: String) { value.withLock { $0.append(token) } }
}

/// Temp `FileStore`, in-memory credentials and one stub API shared by every controller it makes.
@MainActor
private final class Harness {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let credentials = InMemoryCredentialStore()
    let api = StubGitHubAPI()
    let clock = TestClock(localNow)
    let tokens = TokenLog()
    var store: FileStore { FileStore(directory: directory) }

    func makeController(clientID: String = "client-id") -> RadarixController {
        let api = api, tokens = tokens, clock = clock
        return RadarixController(
            store: store, credentials: credentials,
            makeAPI: { token in
                tokens.append(token)
                return api
            },
            oauthClientID: clientID, now: { clock.now })
    }

    /// A signed-in session on disk: settings, credential and the given account. `owners()` answers owner "o".
    func seed(_ account: AccountData, kind: CredentialKind = .oauth) async throws {
        await api.setOwners(.success([user]))
        var settings = AppSettings()
        settings.lastAccountID = account.accountID
        try store.saveSettings(settings)
        try store.saveAccount(account)
        try credentials.save(Credential(token: "stored-token", kind: kind), for: account.accountID)
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: directory)
    }
}

private func record(_ number: Int, _ attention: Attention, repo: RepoRef = repoA, updatedAt: Date = t1) -> ItemRecord {
    ItemRecord(
        item: .fixture(repo: repo.id.rawValue, number: number, commentCount: 3, createdAt: t0, updatedAt: updatedAt),
        attention: attention, seenAt: attention == .seen ? t0 : nil, commentsAtSeen: 0)
}

/// Account 42 ("me") watching every repo of owner "o", with baselined repos.
private func account(_ states: [RepoRef: [ItemRecord]] = [:]) -> AccountData {
    var a = AccountData(accountID: me, login: "me")
    a.watch.owners["o"] = .all(excluded: [])
    for (repo, records) in states {
        a.repos[repo.id] = RepoState(
            repo: repo, baselineAt: t0, highWaterMark: t1,
            records: Dictionary(uniqueKeysWithValues: records.map { ($0.item.key.number, $0) }))
    }
    return a
}

private func key(_ number: Int, _ repo: RepoRef = repoA) -> ItemKey { ItemKey(repo: repo.id, number: number) }

@MainActor
struct RadarixControllerTests {
    @Test func signInWithTokenStoresCredentialAndSyncs() async throws {
        let h = Harness()
        defer { h.cleanUp() }
        await h.api.setOwners(.success([user]))
        let controller = h.makeController()

        try await controller.signIn(token: "pat-123", kind: .personalToken)

        #expect(h.tokens.tokens == ["pat-123"])
        #expect(try h.credentials.load(for: me) == Credential(token: "pat-123", kind: .personalToken))
        #expect(controller.auth == .signedIn(login: "me"))
        #expect(controller.credentialKind == .personalToken)
        #expect(controller.settings.lastAccountID == me)
        #expect(try h.store.loadSettings().lastAccountID == me)
        #expect(controller.owners == [user])
        #expect(controller.lastSyncAt == localNow)
        #expect(!controller.isSyncing)
        // A fresh account watches nothing: the sync asked for owners but fetched no repos.
        #expect(await h.api.calls == [.viewer, .owners])
        #expect(controller.account?.accountID == me)
        #expect(try h.store.loadAccount(me) == controller.account)
    }

    @Test func signInFailureStoresNothing() async throws {
        let h = Harness()
        defer { h.cleanUp() }
        await h.api.setViewer(.failure(.unauthorized))
        let controller = h.makeController()

        await #expect(throws: GitHubError.unauthorized) {
            try await controller.signIn(token: "bad", kind: .personalToken)
        }
        #expect(controller.auth == .signedOut)
        #expect(controller.credentialKind == nil)
        #expect(try h.credentials.load(for: me) == nil)
        #expect(try h.store.loadAccount(me) == nil)
        #expect(controller.settings.lastAccountID == nil)
    }

    @Test func switchingCredentialKindKeepsAccountData() async throws {
        let h = Harness()
        defer { h.cleanUp() }
        await h.api.setOwners(.success([user]))
        let controller = h.makeController()
        try await controller.signIn(token: "oauth-token", kind: .oauth)
        #expect(controller.credentialKind == .oauth)

        await h.api.scriptRepositories("o", .success(.fresh([repoA])))
        await h.api.scriptItems(repoA, .success(.fresh([.fixture(number: 1, updatedAt: t1), .fixture(number: 2, updatedAt: t1)])))
        controller.setOwnerMode(.all(excluded: []), for: "o")
        controller.setNotifications(false, for: repoA.id)
        await controller.pendingRefresh?.value
        let before = try #require(controller.account)
        #expect(before.repos[repoA.id]?.records.count == 2)

        try controller.signOut()
        #expect(controller.credentialKind == nil)
        try await controller.signIn(token: "pat-456", kind: .personalToken)

        #expect(controller.credentialKind == .personalToken)
        #expect(try h.credentials.load(for: me) == Credential(token: "pat-456", kind: .personalToken))
        #expect(controller.account?.watch == before.watch)
        #expect(controller.account?.watch.notificationsOff == [repoA.id])
        #expect(controller.account?.repos[repoA.id]?.records == before.repos[repoA.id]?.records)
    }

    @Test func signOutKeepsDataResetAllDeletesIt() async throws {
        let h = Harness()
        defer { h.cleanUp() }
        await h.api.setOwners(.success([user]))
        let controller = h.makeController()
        try await controller.signIn(token: "t", kind: .oauth)
        controller.setOwnerMode(.all(excluded: []), for: "o")
        await controller.pendingRefresh?.value

        try controller.signOut()
        #expect(controller.auth == .signedOut)
        #expect(controller.account == nil)
        #expect(controller.owners.isEmpty)
        #expect(controller.availableRepos.isEmpty)
        #expect(controller.lastReport == nil)
        #expect(try h.credentials.load(for: me) == nil)
        #expect(try h.store.loadAccount(me)?.watch.owners["o"] == .all(excluded: []))
        #expect(try h.store.loadSettings().lastAccountID == me)

        try await controller.signIn(token: "t", kind: .oauth)
        controller.updateSettings { $0.botDisplay = .hidden }
        try controller.resetAllData()
        #expect(controller.auth == .signedOut)
        #expect(controller.account == nil)
        #expect(controller.credentialKind == nil)
        #expect(controller.settings == AppSettings())
        #expect(try h.credentials.load(for: me) == nil)
        #expect(try h.store.loadAccount(me) == nil)
        #expect(!FileManager.default.fileExists(atPath: h.directory.path))
    }

    @Test func restoreSessionShowsStoredDataWithoutViewerCall() async throws {
        let h = Harness()
        defer { h.cleanUp() }
        try await h.seed(account([repoA: [record(1, .new)]]), kind: .personalToken)
        // Offline: the sync fails, the stored data is still shown.
        await h.api.setOwners(.failure(.network("offline")))
        let controller = h.makeController()

        await controller.restoreSession()

        #expect(controller.auth == .signedIn(login: "me"))
        #expect(controller.credentialKind == .personalToken)
        #expect(h.tokens.tokens == ["stored-token"])
        #expect(await h.api.calls == [.owners])
        #expect(controller.records(in: nil).map(\.item.key) == [key(1)])
    }

    @Test func restoreSessionWithoutCredentialOrAccountFile() async throws {
        let h = Harness()
        defer { h.cleanUp() }
        let empty = h.makeController()
        await empty.restoreSession()
        #expect(empty.auth == .signedOut)

        // Credential but no account file: signs in with the stored credential.
        var settings = AppSettings()
        settings.lastAccountID = me
        try h.store.saveSettings(settings)
        try h.credentials.save(Credential(token: "stored-token", kind: .oauth), for: me)
        let controller = h.makeController()
        await controller.restoreSession()
        #expect(controller.auth == .signedIn(login: "me"))
        #expect(controller.credentialKind == .oauth)
        #expect(try h.store.loadAccount(me) != nil)

        // That sign-in failing leaves everything in place.
        try h.store.resetAll()
        try h.store.saveSettings(settings)
        await h.api.setViewer(.failure(.network("offline")))
        let offline = h.makeController()
        await offline.restoreSession()
        #expect(offline.auth == .signedOut)
        #expect(try h.credentials.load(for: me) != nil)
    }

    @Test func unauthorizedDuringSyncMovesToNeedsReauth() async throws {
        let h = Harness()
        defer { h.cleanUp() }
        try await h.seed(account([repoA: [record(1, .new)]]))
        await h.api.scriptRepositories("o", .failure(.unauthorized))
        let controller = h.makeController()

        await controller.restoreSession()

        #expect(controller.auth == .needsReauth(login: "me"))
        #expect(controller.lastReport?.needsReauth == true)
        #expect(try h.credentials.load(for: me) != nil)
        #expect(controller.account?.repos[repoA.id] != nil)

        await h.api.resetCalls()
        await controller.refresh()
        #expect(await h.api.calls.isEmpty)
    }

    @Test func ownersErrorsFollowTheRules() async throws {
        let h = Harness()
        defer { h.cleanUp() }
        try await h.seed(account())
        await h.api.setOwners(.failure(.network("offline")))
        let controller = h.makeController()

        // No owners known yet: the sync is skipped.
        await controller.restoreSession()
        #expect(await h.api.calls == [.owners])
        #expect(controller.lastSyncAt == nil)

        // Owners known: a later failure syncs with the previous ones.
        await h.api.setOwners(.success([user]))
        await controller.refresh()
        await h.api.setOwners(.failure(.network("offline")))
        await h.api.resetCalls()
        await controller.refresh()
        #expect(controller.owners == [user])
        #expect(await h.api.calls == [.owners, .repositories(owner: "o")])

        // Unauthorized owners call: needs reauth, no sync.
        await h.api.setOwners(.failure(.unauthorized))
        await h.api.resetCalls()
        await controller.refresh()
        #expect(controller.auth == .needsReauth(login: "me"))
        #expect(await h.api.calls == [.owners])
    }

    @Test func refreshSkippedWhileRateLimited() async throws {
        let h = Harness()
        defer { h.cleanUp() }
        try await h.seed(account())
        let resetAt = localNow.addingTimeInterval(900)
        await h.api.setOwners(.failure(.rateLimited(resetAt: resetAt)))
        let controller = h.makeController()
        await controller.restoreSession()
        await h.api.setOwners(.success([user]))

        await h.api.resetCalls()
        h.clock.now = resetAt.addingTimeInterval(-1)
        await controller.refresh()
        #expect(await h.api.calls.isEmpty)

        // A rate limit reported by the sync itself.
        h.clock.now = resetAt
        await h.api.scriptRepositories("o", .failure(.rateLimited(resetAt: resetAt.addingTimeInterval(900))))
        await controller.refresh()
        #expect(await h.api.calls == [.owners, .repositories(owner: "o")])
        #expect(controller.lastReport?.rateLimitedUntil == resetAt.addingTimeInterval(900))

        await h.api.resetCalls()
        h.clock.now = resetAt.addingTimeInterval(899)
        await controller.refresh()
        #expect(await h.api.calls.isEmpty)
    }

    @Test func refreshDoesNothingWhenSignedOut() async {
        let h = Harness()
        defer { h.cleanUp() }
        let controller = h.makeController()
        await controller.refresh()
        #expect(await h.api.calls.isEmpty)
        #expect(controller.lastSyncAt == nil)
    }

    @Test func markSeenPersists() async throws {
        let h = Harness()
        defer { h.cleanUp() }
        try await h.seed(account([repoA: [record(1, .new, updatedAt: t2), record(2, .updated)]]))
        let controller = h.makeController()
        await controller.restoreSession()

        controller.markSeen(key(1))
        controller.markSeen(key(99))

        let seen = try #require(controller.records(in: repoA.id).first { $0.item.key == key(1) })
        #expect(seen.attention == .seen)
        // Server time of the item, never the local clock.
        #expect(seen.seenAt == t2)
        #expect(seen.commentsAtSeen == 3)

        let reloaded = h.makeController()
        await reloaded.restoreSession()
        #expect(reloaded.records(in: repoA.id).first { $0.item.key == key(1) }?.attention == .seen)
        #expect(reloaded.records(in: repoA.id).first { $0.item.key == key(2) }?.attention == .updated)
    }

    @Test func markAllSeenClearsCounts() async throws {
        let h = Harness()
        defer { h.cleanUp() }
        try await h.seed(account([
            repoA: [record(1, .new), record(2, .updated), record(3, .seen)],
            repoB: [record(1, .new, repo: repoB)],
        ]))
        let controller = h.makeController()
        await controller.restoreSession()
        #expect(controller.counts(in: nil) == AttentionCounts(new: 2, updated: 1))
        #expect(controller.counts(in: repoB.id) == AttentionCounts(new: 1, updated: 0))
        #expect(controller.records(in: nil).count == 4)

        controller.markRepoSeen(repoB.id)
        #expect(controller.counts(in: repoB.id).total == 0)
        #expect(controller.counts(in: nil) == AttentionCounts(new: 1, updated: 1))

        controller.markAllSeen()
        #expect(controller.counts(in: nil).total == 0)
        #expect(try h.store.loadAccount(me)?.repos.values.allSatisfy { $0.records.values.allSatisfy { $0.attention == .seen } } == true)

        controller.markUnseen(key(3))
        #expect(controller.counts(in: repoA.id) == AttentionCounts(new: 0, updated: 1))
    }

    @Test func deviceFlowWithoutClientIDThrowsNotConfigured() async {
        let h = Harness()
        defer { h.cleanUp() }
        let controller = h.makeController(clientID: "")
        await #expect(throws: DeviceFlowError.notConfigured) {
            _ = try await controller.startDeviceFlow()
        }
    }

    @Test func markSeenDuringSyncSurvives() async throws {
        let h = Harness()
        defer { h.cleanUp() }
        try await h.seed(account([repoA: [record(1, .new), record(2, .new)]]))
        await h.api.scriptRepositories("o", .success(.fresh([repoA])))
        await h.api.holdItems(repoA)
        let controller = h.makeController()

        let restoring = Task { await controller.restoreSession() }
        await h.api.waitForHeldItems()
        #expect(controller.isSyncing)
        controller.markSeen(key(1))
        controller.setNotifications(false, for: repoA.id)
        await h.api.releaseItems()
        await restoring.value

        #expect(!controller.isSyncing)
        #expect(controller.records(in: repoA.id).first { $0.item.key == key(1) }?.attention == .seen)
        #expect(controller.records(in: repoA.id).first { $0.item.key == key(2) }?.attention == .new)
        #expect(controller.account?.watch.notificationsOff == [repoA.id])
        let stored = try h.store.loadAccount(me)
        #expect(stored?.repos[repoA.id]?.records[1]?.attention == .seen)
        #expect(stored?.watch.notificationsOff == [repoA.id])
    }

    @Test func ownerModeChangeTriggersSync() async throws {
        let h = Harness()
        defer { h.cleanUp() }
        await h.api.setOwners(.success([user]))
        let controller = h.makeController()
        try await controller.signIn(token: "t", kind: .oauth)
        #expect(controller.availableRepos.isEmpty)

        await h.api.scriptRepositories("o", .success(.fresh([repoA, repoB])))
        await h.api.scriptItems(repoA, .success(.fresh([])))
        await h.api.scriptItems(repoB, .success(.fresh([])))
        controller.setOwnerMode(.all(excluded: []), for: "o")
        #expect(try h.store.loadAccount(me)?.watch.owners["o"] == .all(excluded: []))
        await controller.pendingRefresh?.value

        #expect(controller.availableRepos["o"] == [repoA, repoB])
        #expect(controller.account?.repos[repoA.id]?.baselineAt == localNow)
        #expect(controller.account?.repos[repoB.id]?.baselineAt == localNow)
    }

    @Test func watchChangeDuringSyncRunsOneMoreSync() async throws {
        let h = Harness()
        defer { h.cleanUp() }
        try await h.seed(account([repoA: []]))
        await h.api.scriptRepositories("o", .success(.fresh([repoA])), .success(.fresh([repoA])))
        await h.api.holdItems(repoA)
        let controller = h.makeController()

        let restoring = Task { await controller.restoreSession() }
        await h.api.waitForHeldItems()
        controller.setShowArchived(true)
        await h.api.releaseItems()
        await restoring.value
        await controller.pendingRefresh?.value

        let repoCalls = await h.api.calls.filter { $0 == .repositories(owner: "o") }
        #expect(repoCalls.count == 2)
        #expect(controller.account?.watch.showArchived == true)
    }
}
