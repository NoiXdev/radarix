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
        settings.accountIDs = [account.accountID]
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

/// The single-account view these tests were written against, read from the only session.
private extension RadarixController {
    var auth: AuthState {
        guard let session = sessions.first else { return .signedOut }
        return switch session.auth {
        case .ok: .signedIn(login: session.login)
        case .needsReauth: .needsReauth(login: session.login)
        }
    }
    var account: AccountData? { sessions.first?.account }
    var credentialKind: CredentialKind? { sessions.first?.credentialKind }
    var owners: [OwnerRef] { sessions.first?.owners ?? [] }
    var availableRepos: [String: [RepoRef]] { sessions.first?.account.available ?? [:] }
    var lastReport: SyncReport? { sessions.first?.lastReport }
    var syncProblem: SyncProblem? { sessions.first?.syncProblem }
}

@MainActor
private final class Counter {
    var value = 0
}

@MainActor
struct RadarixControllerTests {
    @Test func signInWithTokenStoresCredentialAndSyncs() async throws {
        let h = Harness()
        defer { h.cleanUp() }
        await h.api.setOwners(.success([user]))
        let controller = h.makeController()

        try await controller.addAccount(token: "pat-123", kind: .personalToken)

        #expect(h.tokens.tokens == ["pat-123"])
        #expect(try h.credentials.load(for: me) == Credential(token: "pat-123", kind: .personalToken))
        #expect(controller.auth == .signedIn(login: "me"))
        #expect(controller.credentialKind == .personalToken)
        #expect(controller.settings.accountIDs == [me])
        #expect(try h.store.loadSettings().accountIDs == [me])
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
            try await controller.addAccount(token: "bad", kind: .personalToken)
        }
        #expect(controller.auth == .signedOut)
        #expect(controller.credentialKind == nil)
        #expect(try h.credentials.load(for: me) == nil)
        #expect(try h.store.loadAccount(me) == nil)
        #expect(controller.settings.accountIDs.isEmpty)
    }

    @Test func switchingCredentialKindKeepsAccountData() async throws {
        let h = Harness()
        defer { h.cleanUp() }
        await h.api.setOwners(.success([user]))
        let controller = h.makeController()
        try await controller.addAccount(token: "oauth-token", kind: .oauth)
        #expect(controller.credentialKind == .oauth)

        await h.api.scriptRepositories("o", .success(.fresh([repoA])))
        await h.api.scriptItems(repoA, .success(.fresh([.fixture(number: 1, updatedAt: t1), .fixture(number: 2, updatedAt: t1)])))
        controller.setOwnerMode(.all(excluded: []), for: "o", in: me)
        controller.setNotifications(false, for: repoA.id, in: me)
        await controller.pendingRefresh?.value
        let before = try #require(controller.account)
        #expect(before.repos[repoA.id]?.records.count == 2)

        try controller.removeAccount(me)
        #expect(controller.credentialKind == nil)
        try await controller.addAccount(token: "pat-456", kind: .personalToken)

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
        try await controller.addAccount(token: "t", kind: .oauth)
        controller.setOwnerMode(.all(excluded: []), for: "o", in: me)
        await controller.pendingRefresh?.value

        try controller.removeAccount(me)
        #expect(controller.auth == .signedOut)
        #expect(controller.account == nil)
        #expect(controller.owners.isEmpty)
        #expect(controller.availableRepos.isEmpty)
        #expect(controller.lastReport == nil)
        #expect(try h.credentials.load(for: me) == nil)
        #expect(try h.store.loadAccount(me)?.watch.owners["o"] == .all(excluded: []))
        // Removing drops the account from the list; its file stays.
        #expect(try h.store.loadSettings().accountIDs.isEmpty)

        try await controller.addAccount(token: "t", kind: .oauth)
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

    @Test func resetAllDataRemovesCredentialsOfEveryAccount() async throws {
        let h = Harness()
        defer { h.cleanUp() }
        let other = AccountID(rawValue: 999)
        try await h.seed(account())
        try h.credentials.save(Credential(token: "other", kind: .personalToken), for: other)
        let controller = h.makeController()
        try controller.resetAllData()
        #expect(try h.credentials.load(for: me) == nil)
        #expect(try h.credentials.load(for: other) == nil)
    }

    @Test func resetWhileSignedOutWipesFiles() async throws {
        let h = Harness()
        defer { h.cleanUp() }
        try await h.seed(account())
        let controller = h.makeController()
        #expect(controller.auth == .signedOut)
        try controller.resetAllData()
        #expect(controller.auth == .signedOut)
        #expect(try h.credentials.load(for: me) == nil)
        #expect(!FileManager.default.fileExists(atPath: h.directory.path))
    }

    @Test func restoreSessionShowsStoredDataWithoutViewerCall() async throws {
        let h = Harness()
        defer { h.cleanUp() }
        try await h.seed(account([repoA: [record(1, .new)]]), kind: .personalToken)
        // Offline: the sync fails, the stored data is still shown.
        await h.api.setOwners(.failure(.network("offline")))
        let controller = h.makeController()

        await controller.restoreSessions()

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
        await empty.restoreSessions()
        #expect(empty.auth == .signedOut)

        // Credential but no account file: signs in with the stored credential.
        var settings = AppSettings()
        settings.accountIDs = [me]
        try h.store.saveSettings(settings)
        try h.credentials.save(Credential(token: "stored-token", kind: .oauth), for: me)
        let controller = h.makeController()
        await controller.restoreSessions()
        #expect(controller.auth == .signedIn(login: "me"))
        #expect(controller.credentialKind == .oauth)
        #expect(try h.store.loadAccount(me) != nil)

        // That sign-in failing leaves everything in place.
        try h.store.resetAll()
        try h.store.saveSettings(settings)
        await h.api.setViewer(.failure(.network("offline")))
        let offline = h.makeController()
        await offline.restoreSessions()
        #expect(offline.auth == .signedOut)
        #expect(try h.credentials.load(for: me) != nil)
    }

    @Test func unauthorizedDuringSyncMovesToNeedsReauth() async throws {
        let h = Harness()
        defer { h.cleanUp() }
        try await h.seed(account([repoA: [record(1, .new)]]))
        await h.api.scriptRepositories("o", .failure(.unauthorized))
        let controller = h.makeController()

        await controller.restoreSessions()

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
        await controller.restoreSessions()
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
        await controller.restoreSessions()
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
        await controller.restoreSessions()

        controller.markSeen(key(1))
        controller.markSeen(key(99))

        let seen = try #require(controller.records(in: repoA.id).first { $0.item.key == key(1) })
        #expect(seen.attention == .seen)
        // Server time of the item, never the local clock.
        #expect(seen.seenAt == t2)
        #expect(seen.commentsAtSeen == 3)

        let reloaded = h.makeController()
        await reloaded.restoreSessions()
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
        await controller.restoreSessions()
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

        let restoring = Task { await controller.restoreSessions() }
        await h.api.waitForHeldItems()
        #expect(controller.isSyncing)
        controller.markSeen(key(1))
        controller.setNotifications(false, for: repoA.id, in: me)
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

    @Test func markSeenDuringSyncYieldsToNewerVersion() async throws {
        let h = Harness()
        defer { h.cleanUp() }
        try await h.seed(account([repoA: [record(1, .updated, updatedAt: t1)]]))
        await h.api.scriptRepositories("o", .success(.fresh([repoA])))
        // The sync finds a newer version of item 1 than the one the user marks seen.
        await h.api.scriptItems(repoA, .success(.fresh([.fixture(number: 1, commentCount: 4, createdAt: t0, updatedAt: t2)])))
        await h.api.holdItems(repoA)
        let controller = h.makeController()

        let restoring = Task { await controller.restoreSessions() }
        await h.api.waitForHeldItems()
        controller.markSeen(key(1))
        #expect(controller.records(in: repoA.id).first?.attention == .seen)
        await h.api.releaseItems()
        await restoring.value

        // Re-applying the mark would hide a real update: the record keeps what the sync found.
        let synced = try #require(controller.records(in: repoA.id).first { $0.item.key == key(1) })
        #expect(synced.attention == .updated)
        #expect(synced.item.updatedAt == t2)
        #expect(try h.store.loadAccount(me)?.repos[repoA.id]?.records[1]?.attention == .updated)
    }

    @Test func ownersNetworkErrorSetsOfflineProblem() async throws {
        let h = Harness()
        defer { h.cleanUp() }
        try await h.seed(account([repoA: [record(1, .new)]]))
        await h.api.setOwners(.failure(.network("offline")))
        let controller = h.makeController()
        #expect(controller.syncProblem == nil)

        // Offline launch: no owners known, the sync is skipped, the stored data stays.
        await controller.restoreSessions()
        #expect(controller.syncProblem == .offline)
        #expect(controller.records(in: nil).count == 1)

        // Owners known: the sync falls back to them and still reports the owners failure.
        await h.api.setOwners(.success([user]))
        await controller.refresh()
        #expect(controller.syncProblem == nil)
        await h.api.setOwners(.failure(.network("offline")))
        await controller.refresh()
        #expect(controller.syncProblem == .offline)

        try controller.removeAccount(me)
        #expect(controller.syncProblem == nil)
    }

    @Test func ownersRateLimitSetsRateLimitedProblem() async throws {
        let h = Harness()
        defer { h.cleanUp() }
        try await h.seed(account())
        let resetAt = localNow.addingTimeInterval(900)
        await h.api.setOwners(.failure(.rateLimited(resetAt: resetAt)))
        let controller = h.makeController()

        await controller.restoreSessions()
        #expect(controller.syncProblem == .rateLimited(until: resetAt))

        // A rate limit the engine reports is a problem too.
        h.clock.now = resetAt
        await h.api.setOwners(.success([user]))
        let later = resetAt.addingTimeInterval(900)
        await h.api.scriptRepositories("o", .failure(.rateLimited(resetAt: later)))
        await controller.refresh()
        #expect(controller.syncProblem == .rateLimited(until: later))
    }

    @Test func completedSyncClearsProblem() async throws {
        let h = Harness()
        defer { h.cleanUp() }
        try await h.seed(account())
        await h.api.setOwners(.failure(.network("offline")))
        let controller = h.makeController()
        await controller.restoreSessions()
        #expect(controller.syncProblem == .offline)

        await h.api.setOwners(.success([user]))
        await controller.refresh()
        #expect(controller.syncProblem == nil)
        #expect(controller.lastSyncAt == localNow)
    }

    @Test func lastSyncAtOnlyAfterCompletedSync() async throws {
        let h = Harness()
        defer { h.cleanUp() }
        try await h.seed(account([repoA: [record(1, .seen, updatedAt: t1)]]))
        let resetAt = localNow.addingTimeInterval(900)
        await h.api.scriptRepositories("o", .failure(.rateLimited(resetAt: resetAt)))
        let controller = h.makeController()

        // Stopped by a rate limit.
        await controller.restoreSessions()
        #expect(controller.lastReport?.rateLimitedUntil == resetAt)
        #expect(controller.lastSyncAt == nil)

        // Cancelled: the activity probe for item 1 cancels the sync's task.
        h.clock.now = resetAt
        await h.api.scriptRepositories("o", .success(.fresh([repoA])))
        await h.api.scriptItems(repoA, .success(.fresh([.fixture(number: 1, createdAt: t0, updatedAt: t2)])))
        await h.api.cancelTaskOnActivity(1)
        // Its own task, so cancelling it leaves the test's task alone.
        await Task { await controller.refresh() }.value
        #expect(controller.lastReport?.wasCancelled == true)
        #expect(controller.lastSyncAt == nil)

        // Completed.
        await controller.refresh()
        #expect(controller.lastReport?.wasCancelled == false)
        #expect(controller.lastSyncAt == resetAt)
    }

    @Test func offlineFallbackSyncKeepsLastSyncAt() async throws {
        let h = Harness()
        defer { h.cleanUp() }
        try await h.seed(account([repoA: [record(1, .seen)]]))
        let controller = h.makeController()
        await controller.restoreSessions()
        #expect(controller.lastSyncAt == localNow)

        // Owners are known; the owners call fails, the engine still completes on the known owners.
        let later = localNow.addingTimeInterval(300)
        h.clock.now = later
        await h.api.setOwners(.failure(.network("offline")))
        await controller.refresh()
        #expect(controller.lastReport?.isComplete == true)
        #expect(controller.syncProblem == .offline)
        #expect(controller.lastSyncAt == localNow)
    }

    @Test func needsReauthClearsOfflineProblem() async throws {
        let h = Harness()
        defer { h.cleanUp() }
        try await h.seed(account([repoA: [record(1, .seen)]]))
        let controller = h.makeController()
        await controller.restoreSessions()

        await h.api.setOwners(.failure(.network("offline")))
        await controller.refresh()
        #expect(controller.syncProblem == .offline)

        // Owners fall back to the known list, then the engine meets a 401.
        await h.api.scriptRepositories("o", .failure(.unauthorized))
        await controller.refresh()
        #expect(controller.auth == .needsReauth(login: "me"))
        #expect(controller.syncProblem == nil)
    }

    @Test func ownerModeChangeTriggersSync() async throws {
        let h = Harness()
        defer { h.cleanUp() }
        await h.api.setOwners(.success([user]))
        let controller = h.makeController()
        try await controller.addAccount(token: "t", kind: .oauth)
        #expect(controller.availableRepos.isEmpty)

        await h.api.scriptRepositories("o", .success(.fresh([repoA, repoB])))
        await h.api.scriptItems(repoA, .success(.fresh([])))
        await h.api.scriptItems(repoB, .success(.fresh([])))
        controller.setOwnerMode(.all(excluded: []), for: "o", in: me)
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

        let restoring = Task { await controller.restoreSessions() }
        await h.api.waitForHeldItems()
        controller.setShowArchived(true, in: me)
        await h.api.releaseItems()
        await restoring.value
        await controller.pendingRefresh?.value

        let repoCalls = await h.api.calls.filter { $0 == .repositories(owner: "o") }
        #expect(repoCalls.count == 2)
        #expect(controller.account?.watch.showArchived == true)
    }

    // MARK: Widget snapshot

    @Test func syncWritesSnapshotAndNotifies() async throws {
        let h = Harness()
        defer { h.cleanUp() }
        let bot = ItemRecord(
            item: .fixture(number: 3, author: "dependabot[bot]", updatedAt: t2), attention: .new, seenAt: nil, commentsAtSeen: 0)
        try await h.seed(account([repoA: [record(1, .new), record(2, .seen), bot]]))
        let controller = h.makeController()
        let written = Counter()
        controller.onSnapshotWritten = { written.value += 1 }

        await controller.restoreSessions()

        let snapshot = try #require(try h.store.loadSnapshot())
        #expect(written.value > 0)
        #expect(snapshot.status == .ok)
        #expect(snapshot.logins == ["me"])
        #expect(snapshot.syncedAt == controller.lastSyncAt)
        #expect(snapshot.repos.map(\.id) == [repoA.id])
        #expect(snapshot.repos.first?.newCount == 2)
        #expect(snapshot.repos.first?.items.map(\.key) == [key(3), key(1)])

        // A settings change rewrites it.
        let before = written.value
        controller.updateSettings { $0.botDisplay = .hidden }
        #expect(written.value == before + 1)
        #expect(try h.store.loadSnapshot()?.repos.first?.items.map(\.key) == [key(1)])
    }

    @Test func markSeenUpdatesSnapshot() async throws {
        let h = Harness()
        defer { h.cleanUp() }
        try await h.seed(account([repoA: [record(1, .new), record(2, .updated)]]))
        let controller = h.makeController()
        await controller.restoreSessions()
        let written = Counter()
        controller.onSnapshotWritten = { written.value += 1 }

        controller.markSeen(key(1))

        #expect(written.value == 1)
        let entry = try #require(try h.store.loadSnapshot()?.repos.first)
        #expect(entry.newCount == 0)
        #expect(entry.updatedCount == 1)
        #expect(entry.items.map(\.key) == [key(2)])
    }

    @Test func signOutWritesSignedOutSnapshot() async throws {
        let h = Harness()
        defer { h.cleanUp() }
        try await h.seed(account([repoA: [record(1, .new)]]))
        let controller = h.makeController()
        await controller.restoreSessions()
        #expect(try h.store.loadSnapshot()?.status == .ok)
        let written = Counter()
        controller.onSnapshotWritten = { written.value += 1 }

        try controller.removeAccount(me)

        #expect(written.value == 1)
        #expect(try h.store.loadSnapshot() == .signedOut)

        // A launch without a credential also writes the signed-out snapshot.
        try h.store.removeSnapshot()
        let relaunched = h.makeController()
        await relaunched.restoreSessions()
        #expect(relaunched.auth == .signedOut)
        #expect(try h.store.loadSnapshot() == .signedOut)
    }

    @Test func restoreWithFailingSignInWritesSignedOutSnapshot() async throws {
        let h = Harness()
        defer { h.cleanUp() }
        var settings = AppSettings()
        settings.accountIDs = [me]
        try h.store.saveSettings(settings)
        try h.credentials.save(Credential(token: "stored-token", kind: .oauth), for: me)
        await h.api.setViewer(.failure(.network("offline")))
        let controller = h.makeController()

        await controller.restoreSessions()

        #expect(controller.auth == .signedOut)
        #expect(try h.store.loadSnapshot() == .signedOut)
    }

    @Test func resetRemovesSnapshot() async throws {
        let h = Harness()
        defer { h.cleanUp() }
        try await h.seed(account([repoA: [record(1, .new)]]))
        let controller = h.makeController()
        await controller.restoreSessions()
        #expect(try h.store.loadSnapshot() != nil)
        let written = Counter()
        controller.onSnapshotWritten = { written.value += 1 }

        try controller.resetAllData()

        #expect(try h.store.loadSnapshot() == nil)
        #expect(!FileManager.default.fileExists(atPath: h.directory.path))
        // The widget is told to reload into its signed-out state.
        #expect(written.value == 1)
    }

    @Test func needsReauthSnapshotStatus() async throws {
        let h = Harness()
        defer { h.cleanUp() }
        try await h.seed(account([repoA: [record(1, .new)]]))
        await h.api.scriptRepositories("o", .failure(.unauthorized))
        let controller = h.makeController()

        await controller.restoreSessions()

        #expect(controller.auth == .needsReauth(login: "me"))
        let snapshot = try #require(try h.store.loadSnapshot())
        #expect(snapshot.status == .needsReauth)
        #expect(snapshot.logins == ["me"])
        #expect(snapshot.repos.first?.newCount == 1)

        // An unauthorized owners call changes the status without saving the account.
        try h.store.removeSnapshot()
        await h.api.setOwners(.failure(.unauthorized))
        let other = h.makeController()
        await other.restoreSessions()
        #expect(other.auth == .needsReauth(login: "me"))
        #expect(try h.store.loadSnapshot()?.status == .needsReauth)
    }

    @Test func unchangedSyncsReloadOnce() async throws {
        let h = Harness()
        defer { h.cleanUp() }
        try await h.seed(account([repoA: [record(1, .new)]]))
        let controller = h.makeController()
        await controller.restoreSessions()
        let written = Counter()
        controller.onSnapshotWritten = { written.value += 1 }

        // Two syncs that change nothing: the file gets the new time, the widget is not reloaded.
        h.clock.now = localNow.addingTimeInterval(300)
        await controller.refresh()
        h.clock.now = localNow.addingTimeInterval(600)
        await controller.refresh()
        #expect(written.value == 0)
        #expect(try h.store.loadSnapshot()?.syncedAt == localNow.addingTimeInterval(600))

        h.clock.now = localNow.addingTimeInterval(1_800)
        await controller.refresh()
        #expect(written.value == 0)

        // Once the time the widget last got is an hour old, one sync reloads it.
        h.clock.now = localNow.addingTimeInterval(3_600)
        await controller.refresh()
        #expect(written.value == 1)
        h.clock.now = localNow.addingTimeInterval(3_900)
        await controller.refresh()
        #expect(written.value == 1)
        #expect(try h.store.loadSnapshot()?.syncedAt == localNow.addingTimeInterval(3_900))
    }

    @Test func contentChangeReloads() async throws {
        let h = Harness()
        defer { h.cleanUp() }
        try await h.seed(account([repoA: [record(1, .new)]]))
        let controller = h.makeController()
        await controller.restoreSessions()
        let written = Counter()
        controller.onSnapshotWritten = { written.value += 1 }

        h.clock.now = localNow.addingTimeInterval(60)
        await h.api.scriptRepositories("o", .success(.fresh([repoA])))
        await h.api.scriptItems(repoA, .success(.fresh([.fixture(number: 2, createdAt: t2, updatedAt: t2)])))
        await controller.refresh()

        #expect(written.value == 1)
        #expect(try h.store.loadSnapshot()?.repos.first?.newCount == 2)
        // A mark changes what the widget shows, too.
        controller.markSeen(key(2))
        #expect(written.value == 2)
        // Marking it again changes nothing.
        controller.markSeen(key(2))
        #expect(written.value == 2)
    }

    @Test func snapshotKeepsSyncedAtAcrossLaunches() async throws {
        let h = Harness()
        defer { h.cleanUp() }
        try await h.seed(account([repoA: [record(1, .new)]]))
        let earlier = localNow.addingTimeInterval(-3_600)
        try h.store.saveSnapshot(WidgetSnapshot(status: .ok, logins: ["Me"], reauthLogins: [], syncedAt: earlier, repos: []))
        // Offline: no sync completes, only the session start writes the snapshot.
        await h.api.setOwners(.failure(.network("offline")))
        let controller = h.makeController()

        await controller.restoreSessions()

        #expect(controller.lastSyncAt == nil)
        #expect(try h.store.loadSnapshot()?.syncedAt == earlier)

        // The time of another account is not carried over.
        try h.store.saveSnapshot(WidgetSnapshot(status: .ok, logins: ["someone-else"], reauthLogins: [], syncedAt: earlier, repos: []))
        let other = h.makeController()
        await other.restoreSessions()
        let snapshot = try #require(try h.store.loadSnapshot())
        #expect(snapshot.logins == ["me"])
        #expect(snapshot.syncedAt == nil)
    }

    @Test func failedResetStillEndsSession() async throws {
        let parent = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let directory = parent.appending(path: "data", directoryHint: .isDirectory)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: parent.path)
            try? FileManager.default.removeItem(at: parent)
        }
        let credentials = InMemoryCredentialStore()
        let api = StubGitHubAPI()
        await api.setOwners(.success([user]))
        let controller = RadarixController(
            store: FileStore(directory: directory), credentials: credentials, makeAPI: { _ in api },
            oauthClientID: "client-id", now: { localNow })
        try await controller.addAccount(token: "t", kind: .oauth)
        #expect(controller.auth == .signedIn(login: "me"))
        // The data directory cannot be removed from a read-only parent.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: parent.path)

        #expect(throws: (any Error).self) { try controller.resetAllData() }

        // The credential is gone, so the session is too.
        #expect(try credentials.load(for: me) == nil)
        #expect(controller.auth == .signedOut)
        #expect(controller.account == nil)
        #expect(controller.credentialKind == nil)
    }

    @Test func signInWhileOfflineWritesSignedInSnapshot() async throws {
        let h = Harness()
        defer { h.cleanUp() }
        await h.api.setOwners(.failure(.network("offline")))
        let controller = h.makeController()

        try await controller.addAccount(token: "t", kind: .oauth)

        #expect(controller.auth == .signedIn(login: "me"))
        let snapshot = try #require(try h.store.loadSnapshot())
        #expect(snapshot.status == .ok)
        #expect(snapshot.logins == ["me"])
    }
}
