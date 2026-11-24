import Foundation
import Security
import Synchronization
import Testing
@testable import RadarixKit

private let first = AccountID(rawValue: 1)
private let second = AccountID(rawValue: 2)
private let legacy = AccountID(rawValue: 42)
private let org = OwnerRef(login: "org", kind: .organization)
/// Visible to both accounts.
private let shared = RepoRef.fixture(id: 7, owner: "org", name: "shared")
/// Visible to the second account only.
private let workOnly = RepoRef.fixture(id: 8, owner: "org", name: "work-only")
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

/// Temp `FileStore`, in-memory credentials and one stub API per token:
/// `t-me` is account 1 ("me"), `t-work` is account 2 ("work"), `t-legacy` is account 42 ("me").
@MainActor
private final class Harness {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let credentials = InMemoryCredentialStore()
    let apis: [String: StubGitHubAPI] = ["t-me": StubGitHubAPI(), "t-work": StubGitHubAPI(), "t-legacy": StubGitHubAPI()]
    let clock = TestClock(localNow)
    var store: FileStore { FileStore(directory: directory) }
    var me: StubGitHubAPI { apis["t-me"]! }
    var work: StubGitHubAPI { apis["t-work"]! }
    var legacyAPI: StubGitHubAPI { apis["t-legacy"]! }

    static func make() async -> Harness {
        let h = Harness()
        await h.me.setViewer(.success(Viewer(id: first, login: "me")))
        await h.work.setViewer(.success(Viewer(id: second, login: "work")))
        await h.legacyAPI.setViewer(.success(Viewer(id: legacy, login: "me")))
        for api in h.apis.values { await api.setOwners(.success([org])) }
        return h
    }

    /// Accounts whose credential fails to load, as when Keychain access is denied.
    var deniedLoads: Set<AccountID> = []

    func makeController() -> RadarixController {
        let apis = apis, clock = clock
        return RadarixController(
            store: store, credentials: DenyingCredentialStore(credentials, denied: deniedLoads),
            makeAPI: { token in apis[token] ?? StubGitHubAPI() },
            oauthClientID: "client-id", now: { clock.now })
    }

    /// Settings listing the accounts in this order, their files and credentials.
    func seed(_ accounts: AccountData...) throws {
        var settings = AppSettings()
        settings.accountIDs = accounts.map(\.accountID)
        try store.saveSettings(settings)
        for account in accounts {
            try store.saveAccount(account)
            try credentials.save(Credential(token: Self.token(for: account.accountID), kind: .oauth), for: account.accountID)
        }
    }

    static func token(for id: AccountID) -> String {
        switch id {
        case first: "t-me"
        case second: "t-work"
        default: "t-legacy"
        }
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: directory)
    }
}

/// Passes everything to `inner`, except that loading a denied account's credential throws.
private final class DenyingCredentialStore: CredentialStore, Sendable {
    let inner: InMemoryCredentialStore
    let denied: Set<AccountID>
    init(_ inner: InMemoryCredentialStore, denied: Set<AccountID>) {
        self.inner = inner
        self.denied = denied
    }
    func load(for account: AccountID) throws -> Credential? {
        if denied.contains(account) { throw KeychainError(status: errSecAuthFailed) }
        return try inner.load(for: account)
    }
    func save(_ credential: Credential, for account: AccountID) throws { try inner.save(credential, for: account) }
    func delete(for account: AccountID) throws { try inner.delete(for: account) }
    func deleteAll() throws { try inner.deleteAll() }
}

@MainActor
private final class Reports {
    var all: [(AccountID, SyncReport)] = []
    func of(_ id: AccountID) -> [SyncReport] { all.filter { $0.0 == id }.map(\.1) }
}

private func record(_ number: Int, _ attention: Attention, repo: RepoRef = shared, updatedAt: Date = t1) -> ItemRecord {
    ItemRecord(
        item: .fixture(repo: repo.id.rawValue, number: number, commentCount: 3, createdAt: t0, updatedAt: updatedAt),
        attention: attention, seenAt: attention == .seen ? t0 : nil, commentsAtSeen: 0)
}

/// An account watching every repo of "org", whose last resolved list of "org" is `available`.
private func account(
    _ id: AccountID, available: [RepoRef], states: [RepoRef: [ItemRecord]] = [:]
) -> AccountData {
    var a = AccountData(accountID: id, login: id == second ? "work" : "me")
    a.watch.owners["org"] = .all(excluded: [])
    a.available = ["org": available]
    for (repo, records) in states {
        a.repos[repo.id] = RepoState(
            repo: repo, baselineAt: t0, highWaterMark: t1,
            records: Dictionary(uniqueKeysWithValues: records.map { ($0.item.key.number, $0) }))
    }
    return a
}

private func key(_ number: Int, _ repo: RepoRef = shared) -> ItemKey { ItemKey(repo: repo.id, number: number) }

private func itemCalls(_ calls: [StubGitHubAPI.Call], for repo: RepoRef) -> Int {
    calls.filter { if case .items(let id, _) = $0 { id == repo.id } else { false } }.count
}

@MainActor
struct MultiAccountTests {
    @Test func upgradeFromV2KeepsSession() async throws {
        let h = await Harness.make()
        defer { h.cleanUp() }
        try FileManager.default.createDirectory(at: h.directory, withIntermediateDirectories: true)
        try fixtureJSON("plan2-settings").write(to: h.directory.appending(path: "settings.json"), atomically: true, encoding: .utf8)
        try h.store.saveAccount(account(legacy, available: [shared], states: [shared: [record(1, .new)]]))
        try h.credentials.save(Credential(token: "t-legacy", kind: .oauth), for: legacy)
        // Offline: the stored account is what shows.
        await h.legacyAPI.setOwners(.failure(.network("offline")))
        let controller = h.makeController()
        #expect(controller.settings.accountIDs == [legacy])

        await controller.restoreSessions()

        #expect(controller.sessions.map(\.accountID) == [legacy])
        #expect(controller.isSignedIn)
        #expect(controller.records(in: nil).map(\.item.key) == [key(1)])
    }

    @Test func renderedDescriptionUsesOwningAccount() async throws {
        let h = await Harness.make()
        defer { h.cleanUp() }
        try h.seed(
            account(first, available: [], states: [:]),
            account(second, available: [workOnly], states: [workOnly: [record(3, .new, repo: workOnly)]]))
        await h.work.scriptRenderedBody(3, .success("<p>Work</p>"))
        let controller = h.makeController()
        await controller.restoreSessions()

        let html = try await controller.renderedDescription(of: key(3, workOnly))

        #expect(html == "<p>Work</p>")
        #expect(await h.work.calls.contains(.renderedBody(number: 3, repo: workOnly.id)))
        #expect(await h.me.calls.allSatisfy { if case .renderedBody = $0 { false } else { true } })
    }

    @Test func renderedDescriptionWithoutOwnerThrows() async throws {
        let h = await Harness.make()
        defer { h.cleanUp() }
        try h.seed(account(first, available: []))
        let controller = h.makeController()
        await controller.restoreSessions()

        await #expect(throws: DescriptionError.self) {
            try await controller.renderedDescription(of: key(1, workOnly))
        }
    }

    @Test func controllerAssignUpdatesRecordWithoutChangingAttention() async throws {
        let h = await Harness.make()
        defer { h.cleanUp() }
        try h.seed(
            account(first, available: [], states: [:]),
            account(second, available: [workOnly], states: [workOnly: [record(3, .new, repo: workOnly)]]))
        await h.work.scriptAssigned(3, .success(["bob", "work"]))
        let controller = h.makeController()
        await controller.restoreSessions()
        #expect(controller.isAssignedToOwner(key(3, workOnly)) == false)

        try await controller.setAssigned(true, key: key(3, workOnly))

        #expect(await h.work.calls.contains(.setAssigned(true, login: "work", number: 3, repo: workOnly.id)))
        #expect(await h.me.calls.allSatisfy { if case .setAssigned = $0 { false } else { true } })
        let stored = try #require(controller.records(in: workOnly.id).first)
        #expect(stored.item.assignees == ["bob", "work"])
        #expect(stored.attention == .new)
        #expect(controller.isAssignedToOwner(key(3, workOnly)) == true)
        #expect(try h.store.loadAccount(second)?.repos[workOnly.id]?.records[3]?.item.assignees == ["bob", "work"])
    }

    @Test func controllerAssignWithoutOwnerThrows() async throws {
        let h = await Harness.make()
        defer { h.cleanUp() }
        try h.seed(account(first, available: []))
        let controller = h.makeController()
        await controller.restoreSessions()

        #expect(controller.isAssignedToOwner(key(1, workOnly)) == nil)
        await #expect(throws: AssignError.noOwner) {
            try await controller.setAssigned(true, key: key(1, workOnly))
        }
    }

    @Test func assignDuringSyncSurvivesTheSync() async throws {
        let h = await Harness.make()
        defer { h.cleanUp() }
        try h.seed(
            account(first, available: [shared], states: [shared: [record(1, .seen)]]),
            account(second, available: []))
        await h.me.holdItems(shared)
        await h.me.scriptAssigned(1, .success(["me"]))
        let controller = h.makeController()

        let restoring = Task { await controller.restoreSessions() }
        await h.me.waitForHeldItems()
        try await controller.setAssigned(true, key: key(1))
        #expect(controller.isAssignedToOwner(key(1)) == true)
        await h.me.releaseItems()
        await restoring.value
        await controller.pendingRefresh?.value

        #expect(controller.isAssignedToOwner(key(1)) == true)
        #expect(try h.store.loadAccount(first)?.repos[shared.id]?.records[1]?.item.assignees == ["me"])
    }

    @Test func restoreKeepsAccountWithoutCredentialNeedingSignIn() async throws {
        let h = await Harness.make()
        defer { h.cleanUp() }
        try h.seed(
            account(first, available: [workOnly], states: [workOnly: [record(1, .new, repo: workOnly)]]),
            account(second, available: []))
        try h.credentials.delete(for: first)
        let controller = h.makeController()

        await controller.restoreSessions()

        #expect(controller.sessions.map(\.accountID) == [first, second])
        #expect(controller.settings.accountIDs == [first, second])
        let restored = try #require(controller.session(for: first))
        #expect(restored.auth == .needsReauth)
        #expect(restored.credentialKind == nil)
        #expect(controller.needsReauth.map(\.accountID) == [first])
        #expect(controller.viewers.contains("me"))
        // Its stored data shows; nothing is synced without a credential.
        #expect(controller.records(in: nil).map(\.item.key) == [key(1, workOnly)])
        #expect(await h.me.calls.isEmpty)
        #expect(try h.store.loadSnapshot()?.reauthLogins == ["me"])

        // Signing in again replaces it with a working session.
        try await controller.addAccount(token: "t-me", kind: .oauth)
        #expect(controller.session(for: first)?.auth == .ok)
        #expect(controller.session(for: first)?.credentialKind == .oauth)
        #expect(controller.settings.accountIDs == [first, second])
        #expect(controller.needsReauth.isEmpty)
    }

    @Test func restoreKeepsAccountWhoseCredentialFailsToLoad() async throws {
        let h = await Harness.make()
        defer { h.cleanUp() }
        try h.seed(account(first, available: []), account(second, available: []))
        h.deniedLoads = [first]
        let controller = h.makeController()

        await controller.restoreSessions()

        #expect(controller.sessions.map(\.accountID) == [first, second])
        #expect(controller.session(for: first)?.auth == .needsReauth)
        #expect(controller.session(for: second)?.auth == .ok)

        // Remove works without a loaded credential.
        try controller.removeAccount(first)
        #expect(controller.sessions.map(\.accountID) == [second])
        #expect(controller.settings.accountIDs == [second])
    }

    @Test func accountWithoutCredentialKeepsSharedRepo() async throws {
        let h = await Harness.make()
        defer { h.cleanUp() }
        try h.seed(
            account(first, available: [shared], states: [shared: [record(1, .new)]]),
            account(second, available: []))
        try h.credentials.delete(for: first)
        await h.work.scriptRepositories("org", .success(.fresh([shared])))
        let controller = h.makeController()

        await controller.restoreSessions()

        #expect(controller.ownership[shared.id] == first)
        #expect(controller.owner(of: shared.id)?.accountID == first)
        #expect(itemCalls(await h.work.calls, for: shared) == 0)
        #expect(controller.session(for: second)?.account.repos[shared.id] == nil)
        #expect(controller.records(in: shared.id).map(\.item.key) == [key(1)])
    }

    @Test func restoreSkipsCredentialOfAnotherAccountWithoutFile() async throws {
        let h = await Harness.make()
        defer { h.cleanUp() }
        try h.seed(account(second, available: [workOnly], states: [workOnly: [record(1, .new, repo: workOnly)]]))
        var settings = try h.store.loadSettings()
        settings.accountIDs = [first, second]
        try h.store.saveSettings(settings)
        // The first account has no file, and its credential signs in as the second account.
        try h.credentials.save(Credential(token: "t-work", kind: .oauth), for: first)
        let controller = h.makeController()

        await controller.restoreSessions()

        #expect(controller.sessions.map(\.accountID) == [second])
        #expect(controller.settings.accountIDs == [first, second])
        #expect(try h.store.loadAccount(first) == nil)
        #expect(controller.records(in: nil).map(\.item.key) == [key(1, workOnly)])
    }

    @Test func addSecondAccountAppends() async throws {
        let h = await Harness.make()
        defer { h.cleanUp() }
        let controller = h.makeController()
        #expect(!controller.isSignedIn)

        try await controller.addAccount(token: "t-me", kind: .oauth)
        try await controller.addAccount(token: "t-work", kind: .personalToken)

        #expect(controller.settings.accountIDs == [first, second])
        #expect(try h.store.loadSettings().accountIDs == [first, second])
        #expect(controller.sessions.map(\.accountID) == [first, second])
        #expect(controller.session(for: second)?.credentialKind == .personalToken)
        #expect(try h.credentials.load(for: second) == Credential(token: "t-work", kind: .personalToken))
        #expect(controller.viewers.contains("work"))
        #expect(controller.viewers.contains("ME"))
        #expect(controller.isSignedIn)
    }

    @Test func addingSameAccountTwiceKeepsOneEntry() async throws {
        let h = await Harness.make()
        defer { h.cleanUp() }
        let controller = h.makeController()

        try await controller.addAccount(token: "t-me", kind: .oauth)
        try await controller.addAccount(token: "t-me", kind: .personalToken)

        #expect(controller.settings.accountIDs == [first])
        #expect(controller.sessions.map(\.accountID) == [first])
        #expect(controller.session(for: first)?.credentialKind == .personalToken)
        #expect(try h.credentials.load(for: first)?.kind == .personalToken)
    }

    @Test func addAccountTellsWhetherTheAccountIsNew() async throws {
        let h = await Harness.make()
        defer { h.cleanUp() }
        let controller = h.makeController()

        let added = try await controller.addAccount(token: "t-me", kind: .oauth)
        let again = try await controller.addAccount(token: "t-me", kind: .oauth)
        let work = try await controller.addAccount(token: "t-work", kind: .personalToken)

        #expect(added == AddedAccount(accountID: first, login: "me", isNew: true))
        #expect(again == AddedAccount(accountID: first, login: "me", isNew: false))
        #expect(work == AddedAccount(accountID: second, login: "work", isNew: true))
    }

    @Test func sharedRepoListedOnce() async throws {
        let h = await Harness.make()
        defer { h.cleanUp() }
        // The second account still has an old state of the shared repo.
        try h.seed(
            account(first, available: [shared], states: [shared: []]),
            account(second, available: [shared], states: [shared: [record(5, .new)]]))
        let issue = Item.fixture(repo: shared.id.rawValue, number: 5, createdAt: t2, updatedAt: t2)
        for api in [h.me, h.work] {
            await api.scriptRepositories("org", .success(.fresh([shared])))
            await api.scriptItems(shared, .success(.fresh([issue])))
        }
        let controller = h.makeController()
        let reports = Reports()
        controller.onSyncReport = { account, report in reports.all.append((account.accountID, report)) }

        await controller.restoreSessions()

        #expect(controller.records(in: nil).count == 1)
        #expect(controller.counts(in: nil).new == 1)
        #expect(controller.ownership[shared.id] == first)
        #expect(controller.owner(of: shared.id)?.accountID == first)
        #expect(controller.session(for: second)?.account.repos[shared.id] == nil)
        #expect(try h.store.loadAccount(second)?.repos[shared.id] == nil)
        #expect(itemCalls(await h.work.calls, for: shared) == 0)
        #expect(reports.of(first).flatMap(\.newItems).map(\.key) == [key(5)])
        #expect(reports.of(second).count == 1)
        #expect(reports.of(second).flatMap(\.newItems).isEmpty)
    }

    @Test func reauthAccountDoesNotStopOthers() async throws {
        let h = await Harness.make()
        defer { h.cleanUp() }
        try h.seed(
            account(first, available: [shared], states: [shared: []]),
            account(second, available: [shared, workOnly], states: [workOnly: [record(1, .new, repo: workOnly)]]))
        await h.work.setOwners(.failure(.unauthorized))
        await h.me.scriptItems(shared, .success(.fresh([.fixture(repo: shared.id.rawValue, number: 5, createdAt: t2, updatedAt: t2)])))
        let controller = h.makeController()

        await controller.restoreSessions()

        #expect(controller.session(for: first)?.account.repos[shared.id]?.records[5]?.attention == .new)
        #expect(controller.session(for: second)?.auth == .needsReauth)
        #expect(controller.needsReauth.map(\.accountID) == [second])
        #expect(controller.ownership[workOnly.id] == second)
        #expect(controller.records(in: nil).map(\.item.key).contains(key(1, workOnly)))
        #expect(controller.records(in: nil).map(\.item.key).contains(key(5)))
    }

    @Test func unhealthyOwnerKeepsSharedRepo() async throws {
        let h = await Harness.make()
        defer { h.cleanUp() }
        try h.seed(
            account(first, available: [shared], states: [shared: [record(1, .seen)]]),
            account(second, available: []))
        // No owners known for the first account: it cannot resolve in this pass.
        await h.me.setOwners(.failure(.network("offline")))
        await h.work.scriptRepositories("org", .success(.fresh([shared])))
        let controller = h.makeController()

        await controller.restoreSessions()

        #expect(controller.session(for: first)?.syncProblem == .offline)
        #expect(controller.ownership[shared.id] == first)
        #expect(itemCalls(await h.work.calls, for: shared) == 0)
        #expect(controller.session(for: second)?.account.repos[shared.id] == nil)
        #expect(controller.records(in: shared.id).map(\.item.key) == [key(1)])
    }

    @Test func takeoverBaselinesWithoutNewItems() async throws {
        let h = await Harness.make()
        defer { h.cleanUp() }
        try h.seed(
            account(first, available: [shared], states: [shared: [record(1, .seen), record(2, .seen)]]),
            account(second, available: [shared]))
        let controller = h.makeController()
        let reports = Reports()
        controller.onSyncReport = { account, report in reports.all.append((account.accountID, report)) }
        await controller.restoreSessions()
        #expect(controller.ownership[shared.id] == first)
        reports.all = []

        await h.work.scriptItems(shared, .success(.fresh([
            .fixture(repo: shared.id.rawValue, number: 1, createdAt: t0, updatedAt: t1),
            .fixture(repo: shared.id.rawValue, number: 2, createdAt: t0, updatedAt: t1),
        ])))
        try controller.removeAccount(first)
        await controller.refresh()
        await controller.pendingRefresh?.value

        #expect(controller.ownership[shared.id] == second)
        let listed = controller.records(in: nil)
        #expect(Set(listed.map(\.item.key)) == [key(1), key(2)])
        #expect(listed.allSatisfy { $0.attention == .seen })
        #expect(!reports.of(second).isEmpty)
        #expect(reports.of(second).allSatisfy { $0.newItems.isEmpty })
    }

    @Test func reAddedAccountGoesLastAndDropsForeignState() async throws {
        let h = await Harness.make()
        defer { h.cleanUp() }
        try h.seed(
            account(first, available: [shared], states: [shared: [record(1, .new)]]),
            account(second, available: [shared]))
        await h.work.scriptItems(shared, .success(.fresh([.fixture(repo: shared.id.rawValue, number: 1, createdAt: t0, updatedAt: t1)])))
        let controller = h.makeController()
        await controller.restoreSessions()

        try controller.removeAccount(first)
        await controller.refresh()
        await controller.pendingRefresh?.value
        #expect(controller.ownership[shared.id] == second)
        // The removed account's file still holds its old state of the repo.
        #expect(try h.store.loadAccount(first)?.repos[shared.id] != nil)

        try await controller.addAccount(token: "t-me", kind: .oauth)

        #expect(controller.settings.accountIDs == [second, first])
        #expect(controller.sessions.map(\.accountID) == [second, first])
        #expect(controller.ownership[shared.id] == second)
        #expect(controller.session(for: first)?.account.repos[shared.id] == nil)
        #expect(try h.store.loadAccount(first)?.repos[shared.id] == nil)
        #expect(controller.records(in: shared.id).map(\.attention) == [.seen])
    }

    @Test func ownActivityFromOtherAccountStaysSeen() async throws {
        let h = await Harness.make()
        defer { h.cleanUp() }
        try h.seed(
            account(first, available: [shared], states: [shared: [record(1, .seen)]]),
            account(second, available: [shared]))
        // The seen issue moved; only the other account commented.
        await h.me.scriptItems(shared, .success(.fresh([.fixture(repo: shared.id.rawValue, number: 1, createdAt: t0, updatedAt: t2)])))
        await h.me.scriptTimeline(1, actors: ["work"])
        let controller = h.makeController()

        await controller.restoreSessions()

        #expect(await h.me.calls.contains { if case .activity(1, _, _) = $0 { true } else { false } })
        let synced = try #require(controller.records(in: shared.id).first)
        #expect(synced.item.updatedAt == t2)
        #expect(synced.attention == .seen)
    }

    @Test func markRoutesToOwningSession() async throws {
        let h = await Harness.make()
        defer { h.cleanUp() }
        try h.seed(
            account(first, available: [shared], states: [shared: [record(1, .new)]]),
            account(second, available: [shared], states: [shared: [record(1, .new)]]))
        let controller = h.makeController()
        await controller.restoreSessions()

        controller.markSeen(key(1))

        #expect(controller.session(for: first)?.account.repos[shared.id]?.records[1]?.attention == .seen)
        #expect(try h.store.loadAccount(first)?.repos[shared.id]?.records[1]?.attention == .seen)
        #expect(controller.session(for: second)?.account.repos[shared.id] == nil)
        #expect(controller.counts(in: nil).total == 0)

        controller.markUnseen(key(1))
        #expect(controller.counts(in: shared.id) == AttentionCounts(new: 0, updated: 1))
        controller.markRepoSeen(shared.id)
        #expect(controller.counts(in: nil).total == 0)
    }

    @Test func markAllSeenReachesEverySession() async throws {
        let h = await Harness.make()
        defer { h.cleanUp() }
        try h.seed(
            account(first, available: [shared], states: [shared: [record(1, .new)]]),
            account(second, available: [workOnly], states: [workOnly: [record(1, .updated, repo: workOnly)]]))
        let controller = h.makeController()
        await controller.restoreSessions()
        #expect(controller.counts(in: nil) == AttentionCounts(new: 1, updated: 1))

        controller.markAllSeen()

        #expect(controller.counts(in: nil).total == 0)
        #expect(try h.store.loadAccount(second)?.repos[workOnly.id]?.records[1]?.attention == .seen)
    }

    @Test func snapshotCoversAllAccounts() async throws {
        let h = await Harness.make()
        defer { h.cleanUp() }
        try h.seed(
            account(first, available: [shared], states: [shared: [record(1, .new)]]),
            account(second, available: [workOnly], states: [workOnly: [record(1, .new, repo: workOnly)]]))
        let controller = h.makeController()
        await controller.restoreSessions()

        let snapshot = try #require(try h.store.loadSnapshot())
        #expect(snapshot.summary(for: .all).newCount == 2)
        #expect(snapshot.logins == ["me", "work"])
        #expect(snapshot.reauthLogins == [])
        #expect(snapshot.status == .ok)
    }

    @Test func markAllSeenWritesSnapshotOnce() async throws {
        let h = await Harness.make()
        defer { h.cleanUp() }
        try h.seed(
            account(first, available: [shared], states: [shared: [record(1, .new)]]),
            account(second, available: [workOnly], states: [workOnly: [record(1, .new, repo: workOnly)]]))
        let controller = h.makeController()
        await controller.restoreSessions()
        var reloads = 0
        controller.onSnapshotWritten = { reloads += 1 }

        controller.markAllSeen()

        #expect(reloads == 1)
        #expect(try h.store.loadSnapshot()?.summary(for: .all).newCount == 0)
    }

    @Test func markDuringSyncOnRemovedOwnerIsDropped() async throws {
        let h = await Harness.make()
        defer { h.cleanUp() }
        try h.seed(
            account(first, available: [shared], states: [shared: [record(1, .new)]]),
            account(second, available: [shared]))
        await h.me.holdItems(shared)
        let controller = h.makeController()

        let restoring = Task { await controller.restoreSessions() }
        await h.me.waitForHeldItems()
        try controller.removeAccount(first)
        controller.markSeen(key(1))

        #expect(controller.owner(of: shared.id) == nil)
        #expect(controller.session(for: second)?.account.repos[shared.id] == nil)
        #expect(controller.records(in: shared.id).isEmpty)
        await h.me.releaseItems()
        await restoring.value
        await controller.pendingRefresh?.value

        #expect(controller.sessions.map(\.accountID) == [second])
        // The ended session neither applied the mark nor saved its discarded sync.
        #expect(try h.store.loadAccount(first)?.repos[shared.id]?.records[1]?.attention == .new)
        #expect(controller.ownership[shared.id] == second)
        #expect(controller.session(for: second)?.account.repos[shared.id]?.records[1] == nil)
    }

    @Test func lastSyncAtIsOldestHealthy() async throws {
        let h = await Harness.make()
        defer { h.cleanUp() }
        try h.seed(account(first, available: []), account(second, available: []))
        let controller = h.makeController()
        #expect(controller.lastSyncAt == nil)
        await controller.restoreSessions()
        let syncedFirst = localNow
        #expect(controller.lastSyncAt == syncedFirst)

        // The first account falls back to its known owners while offline: its time stays.
        let syncedSecond = localNow.addingTimeInterval(300)
        h.clock.now = syncedSecond
        await h.me.setOwners(.failure(.network("offline")))
        await controller.refresh()
        #expect(controller.session(for: first)?.lastSyncAt == syncedFirst)
        #expect(controller.session(for: second)?.lastSyncAt == syncedSecond)
        #expect(controller.lastSyncAt == syncedFirst)

        // A session that needs reauth no longer counts.
        h.clock.now = localNow.addingTimeInterval(600)
        await h.me.setOwners(.failure(.unauthorized))
        await h.work.setOwners(.failure(.network("offline")))
        await controller.refresh()
        #expect(controller.session(for: first)?.auth == .needsReauth)
        #expect(controller.lastSyncAt == syncedSecond)

        // Every session needs reauth: the oldest of all.
        await h.work.setOwners(.failure(.unauthorized))
        await controller.refresh()
        #expect(controller.needsReauth.count == 2)
        #expect(controller.lastSyncAt == syncedFirst)
    }

    @Test func lastSyncAtNilWhileAnySessionNeverSynced() async throws {
        let h = await Harness.make()
        defer { h.cleanUp() }
        try h.seed(account(first, available: []), account(second, available: []))
        await h.work.setOwners(.failure(.network("offline")))
        let controller = h.makeController()

        await controller.restoreSessions()

        #expect(controller.session(for: first)?.lastSyncAt == localNow)
        #expect(controller.lastSyncAt == nil)
    }

    @Test func removeKeepsAccountFile() async throws {
        let h = await Harness.make()
        defer { h.cleanUp() }
        let controller = h.makeController()
        try await controller.addAccount(token: "t-me", kind: .oauth)
        try await controller.addAccount(token: "t-work", kind: .oauth)

        try controller.removeAccount(second)

        #expect(FileManager.default.fileExists(atPath: h.directory.appending(path: "accounts/2.json").path))
        #expect(try h.credentials.load(for: second) == nil)
        #expect(try h.credentials.load(for: first) != nil)
        #expect(controller.settings.accountIDs == [first])
        #expect(try h.store.loadSettings().accountIDs == [first])
        #expect(controller.sessions.map(\.accountID) == [first])
        #expect(!controller.viewers.contains("work"))
    }

    @Test func restoreAssignsOwnershipBeforeFirstPass() async throws {
        let h = await Harness.make()
        defer { h.cleanUp() }
        // The first account still holds an old state of a repo it no longer lists.
        try h.seed(
            account(first, available: [], states: [shared: [record(1, .new)]]),
            account(second, available: [shared], states: [shared: [record(2, .new), record(3, .new)]]))
        let controller = h.makeController()
        var snapshots: [WidgetSnapshot] = []
        controller.onSnapshotWritten = { if let snapshot = try? h.store.loadSnapshot() { snapshots.append(snapshot) } }

        await controller.restoreSessions()

        // The snapshot written before the first pass already follows the ownership rule.
        let atRestore = try #require(snapshots.first)
        #expect(atRestore.summary(for: .all).newCount == 2)
        #expect(controller.ownership[shared.id] == second)
    }

    @Test func reAddMidPassCarriesSyncState() async throws {
        let h = await Harness.make()
        defer { h.cleanUp() }
        try h.seed(account(first, available: [shared], states: [shared: [record(1, .seen)]]))
        let controller = h.makeController()
        await controller.restoreSessions()
        let old = try #require(controller.session(for: first))
        #expect(old.lastSyncAt == localNow)
        #expect(old.owners == [org])
        #expect(old.lastReport != nil)
        #expect(try h.store.loadSnapshot()?.syncedAt == localNow)

        h.clock.now = localNow.addingTimeInterval(300)
        await h.me.holdItems(shared)
        let pass = Task { await controller.refresh() }
        await h.me.waitForHeldItems()

        // Returns without waiting for the running pass.
        try await controller.addAccount(token: "t-me", kind: .personalToken)

        let renewed = try #require(controller.session(for: first))
        #expect(renewed !== old)
        #expect(renewed.auth == .ok)
        #expect(renewed.credentialKind == .personalToken)
        #expect(renewed.owners == [org])
        #expect(renewed.lastSyncAt == localNow)
        #expect(renewed.lastReport == old.lastReport)
        #expect(renewed.unknownOwners == old.unknownOwners)
        #expect(renewed.rateLimitedUntil == old.rateLimitedUntil)
        #expect(controller.lastSyncAt == localNow)
        #expect(try h.store.loadSnapshot()?.syncedAt == localNow)

        await h.me.releaseItems()
        await pass.value
        await controller.pendingRefresh?.value

        // The ended session's pass was discarded; a follow-up pass synced the new one.
        #expect(controller.sessions.count == 1)
        #expect(controller.session(for: first) === renewed)
        #expect(renewed.lastSyncAt == localNow.addingTimeInterval(300))
        #expect(itemCalls(await h.me.calls, for: shared) == 3)
    }

    @Test func reAddKeepsRateLimit() async throws {
        let h = await Harness.make()
        defer { h.cleanUp() }
        try h.seed(account(first, available: []))
        let reset = localNow.addingTimeInterval(900)
        await h.me.setOwners(.failure(.rateLimited(resetAt: reset)))
        let controller = h.makeController()
        await controller.restoreSessions()
        #expect(controller.session(for: first)?.rateLimitedUntil == reset)
        await h.me.resetCalls()

        try await controller.addAccount(token: "t-me", kind: .oauth)

        #expect(controller.session(for: first)?.rateLimitedUntil == reset)
        // The new session waits for the reset as well.
        #expect(await h.me.calls == [.viewer])
    }

    @Test func addAccountMidPassSyncsAfterRunningPass() async throws {
        let h = await Harness.make()
        defer { h.cleanUp() }
        try h.seed(account(first, available: [shared], states: [shared: []]))
        // A stored file of the second account, which is not in the list yet.
        try h.store.saveAccount(account(second, available: [shared, workOnly]))
        await h.me.holdItems(shared)
        let controller = h.makeController()
        let restoring = Task { await controller.restoreSessions() }
        await h.me.waitForHeldItems()

        // Returns without waiting for the running pass.
        try await controller.addAccount(token: "t-work", kind: .oauth)

        #expect(controller.sessions.map(\.accountID) == [first, second])
        #expect(await h.work.calls == [.viewer])
        await h.me.releaseItems()
        await restoring.value
        await controller.pendingRefresh?.value

        #expect(controller.ownership[shared.id] == first)
        #expect(controller.ownership[workOnly.id] == second)
        #expect(itemCalls(await h.work.calls, for: workOnly) == 1)
        #expect(itemCalls(await h.work.calls, for: shared) == 0)
        #expect(controller.session(for: second)?.lastSyncAt == localNow)
    }
}
