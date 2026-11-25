import Foundation
import Observation
import os

/// Whether GitHub still accepts an account's credential.
public enum SessionAuth: Sendable, Equatable {
    case ok, needsReauth
}

/// One signed-in GitHub account: its data, credential kind, sync state and marks.
///
/// A sync pass is split in two steps so a workspace can decide repo ownership in between:
/// `resolve()` fetches the owners and their repo lists, `syncItems(owned:keep:viewers:)` syncs the
/// items of the repos this account owns.
@MainActor @Observable
public final class AccountSession {
    public let accountID: AccountID
    public private(set) var account: AccountData
    public var login: String { account.login }
    /// How the account signed in; nil for a session restored without a credential.
    public let credentialKind: CredentialKind?
    public private(set) var auth: SessionAuth = .ok
    public private(set) var owners: [OwnerRef] = []
    public private(set) var lastReport: SyncReport?
    /// When the last sync that processed every watched repo finished.
    public private(set) var lastSyncAt: Date?
    /// Set when the last sync attempt hit a problem; cleared by a completed sync.
    public private(set) var syncProblem: SyncProblem?
    /// No sync before this time.
    public private(set) var rateLimitedUntil: Date?
    /// True from `resolve()` until the pass ends for this account.
    public private(set) var isSyncing = false
    /// Active owners without any repo list, from the last `resolve()` that fetched repo lists.
    public private(set) var unknownOwners: Set<String> = []

    /// Called after a watch change that affects what is synced.
    @ObservationIgnored var onWatchChanged: (@MainActor () -> Void)?
    /// Called after every account save.
    @ObservationIgnored var onSaved: (@MainActor () -> Void)?
    /// The report of a pass that `resolve()` ended (rejected sign-in, rate limit or cancellation
    /// while fetching repo lists); nil when the last `resolve()` returned true or failed earlier.
    @ObservationIgnored private(set) var stoppedReport: SyncReport?

    private let api: GitHubAPI
    private let store: FileStore
    private let now: @Sendable () -> Date

    /// Changes when the session ends; work started before is discarded.
    @ObservationIgnored private var generation = 0
    /// Set by `end()`.
    @ObservationIgnored private var hasEnded = false
    /// Cancels the API work running for this session.
    @ObservationIgnored private var cancelRunning: (() -> Void)?
    /// What `syncItems` needs from the last `resolve()` that returned true.
    @ObservationIgnored private var pass: Pass?
    /// Marks made while items sync, re-applied to the result.
    @ObservationIgnored private var journal: [Mark] = []
    /// `syncRepo` is running. Unlike a pass it leaves `isSyncing` alone.
    @ObservationIgnored private var isSyncingRepo = false

    private static let log = Logger(subsystem: "dev.noix.radarix", category: "session")

    private struct Pass {
        var resolution: Resolution
        /// The owners call failed for lack of network; the pass runs on the known owners.
        var offline: Bool
    }

    private enum Mark {
        /// `version` is the `updatedAt` of the record the user marked.
        case seen(ItemKey, version: Date)
        case unseen(ItemKey)
        case assignees(ItemKey, [String])

        var repo: RepoID {
            switch self {
            case .seen(let key, _), .unseen(let key), .assignees(let key, _): key.repo
            }
        }
    }

    public init(
        account: AccountData, credential: Credential, api: GitHubAPI, store: FileStore,
        now: @escaping @Sendable () -> Date
    ) {
        accountID = account.accountID
        self.account = account
        credentialKind = credential.kind
        self.api = api
        self.store = store
        self.now = now
    }

    /// A session for an account whose credential is missing, cannot be read or belongs to another
    /// account: it shows the stored data, keeps its repos and needs a new sign-in. It never syncs.
    public init(withoutCredential account: AccountData, store: FileStore, now: @escaping @Sendable () -> Date) {
        accountID = account.accountID
        self.account = account
        credentialKind = nil
        auth = .needsReauth
        api = RejectingAPI()
        self.store = store
        self.now = now
    }

    /// Takes over what an earlier session of the same account knew, so a new sign-in does not
    /// reset the owners, the last sync or a running rate limit. Call before the first sync.
    func adopt(from previous: AccountSession) {
        owners = previous.owners
        lastSyncAt = previous.lastSyncAt
        lastReport = previous.lastReport
        rateLimitedUntil = previous.rateLimitedUntil
        unknownOwners = previous.unknownOwners
    }

    /// Cancels running work and discards its result. The session is not used afterwards.
    public func end() {
        generation += 1
        hasEnded = true
        cancelRunning?()
        cancelRunning = nil
        isSyncing = false
        pass = nil
        journal = []
    }

    // MARK: Sync

    /// Fetches the owners and their repo lists and persists `account.available`. Returns false when
    /// this account must not sync items in this pass: rejected sign-in, rate limit, no owners known,
    /// a stop while fetching repo lists (recorded in `lastReport`), or the session ended.
    public func resolve() async -> Bool {
        stoppedReport = nil
        pass = nil
        journal = []
        guard auth == .ok else { return false }
        if let until = rateLimitedUntil, now() < until { return false }
        isSyncing = true
        let proceeds = await resolvePass()
        if !proceeds { isSyncing = false }
        return proceeds
    }

    private func resolvePass() async -> Bool {
        let generation = self.generation
        let fetchedOwners: [OwnerRef]
        var offline = false
        let result: Result<[OwnerRef], any Error> = await cancellable { [api] in
            do { return .success(try await api.owners()) } catch { return .failure(error) }
        }
        switch result {
        case .success(let owners):
            fetchedOwners = owners
        case .failure(let error):
            guard generation == self.generation else { return false }
            switch error as? GitHubError {
            case .unauthorized:
                // One 401 is not a rejected sign-in: GitHub must say it again.
                guard await rejectionConfirmed() else { return false }
                guard generation == self.generation else { return false }
                auth = .needsReauth
                // GitHub answered; the sign-in is the problem, shown by `auth`.
                syncProblem = nil
                return false
            case .rateLimited(let resetAt):
                rateLimitedUntil = resetAt
                syncProblem = .rateLimited(until: resetAt)
                return false
            default:
                if case .network = error as? GitHubError {
                    offline = true
                    syncProblem = .offline
                }
                // Keep the previous owners; without any, try again next time.
                guard !owners.isEmpty else { return false }
                fetchedOwners = owners
            }
        }
        guard generation == self.generation else { return false }
        owners = fetchedOwners

        let snapshot = account
        let resolution = await cancellable { [api, now] in
            await SyncEngine(api: api, now: now).resolve(snapshot, owners: fetchedOwners)
        }
        guard generation == self.generation else { return false }
        unknownOwners = resolution.unknownOwners

        if let stop = resolution.stop {
            // Nothing was synced yet: the account stays as it was.
            var report = SyncReport()
            report.record(stop)
            report.rateLimit = await cancellable { [api] in await api.rateLimit() }
            guard generation == self.generation else { return false }
            await withholdUnconfirmedRejection(&report)
            guard generation == self.generation else { return false }
            report.availableRepos = resolution.available
            report.ownerIssues = resolution.ownerIssues
            account.available = resolution.available
            if adoptStats(from: resolution) { save() }
            stoppedReport = report
            finish(report, offline: offline)
            return false
        }

        let availableChanged = account.available != resolution.available
        if availableChanged { account.available = resolution.available }
        if adoptStats(from: resolution) || availableChanged { save() }
        pass = Pass(resolution: resolution, offline: offline)
        return true
    }

    /// Overwrites the stored stats with the fresh ones and drops those of repos no longer in
    /// `account.available`. Returns whether the stored stats changed. Call after `available` is set.
    private func adoptStats(from resolution: Resolution) -> Bool {
        let listed = Set(account.available.values.joined().map(\.id))
        let merged = account.stats.merging(resolution.stats) { _, fresh in fresh }.filter { listed.contains($0.key) }
        guard merged != account.stats else { return false }
        account.stats = merged
        return true
    }

    /// `RepoResolver.watched` for this account's watch config and repo lists.
    public func watchedRepos() -> [RepoRef] {
        RepoResolver.watched(config: account.watch, available: account.available)
    }

    /// Syncs the items of `owned` after a `resolve()` that returned true, merges what changed
    /// meanwhile and saves. Returns nil when the session ended meanwhile.
    ///
    /// Every `resolve()` that returned true must be followed by exactly one call, also with
    /// `owned: []`: until then the session is mid-pass, and this call drops the states of repos
    /// it neither owns nor keeps.
    public func syncItems(owned: [RepoRef], keep: Set<RepoID>, viewers: ViewerLogins) async -> SyncReport? {
        let generation = self.generation
        guard let pass else {
            assert(hasEnded, "syncItems needs a preceding resolve() that returned true")
            return nil
        }
        self.pass = nil
        isSyncing = true
        // Everything until now is in the snapshot.
        let snapshot = account
        journal = []
        var (synced, report) = await cancellable { [api, now] in
            await SyncEngine(api: api, now: now).sync(snapshot, owned: owned, keep: keep, viewers: viewers)
        }
        guard generation == self.generation else { return nil }
        await withholdUnconfirmedRejection(&report)
        guard generation == self.generation else { return nil }
        report.availableRepos = pass.resolution.available
        report.ownerIssues = pass.resolution.ownerIssues

        // Changes made during the sync win over the snapshot the engine worked on.
        synced.watch = account.watch
        synced.available = account.available
        for mark in journal { Self.apply(mark, to: &synced) }
        journal = []
        account = synced
        finish(report, offline: pass.offline)
        return report
    }

    /// Syncs the items of `ref` alone, outside a pass, with the engine code of a pass. Marks made
    /// meanwhile win over the result, as in `syncItems`; every other repo state stays as it is.
    /// Returns nil, without a request, when this account must not sync (rejected sign-in, a rate
    /// limit that has not reset, a pass or another repo sync in progress), and when the session
    /// ended meanwhile.
    ///
    /// Only this repo's entries of `lastReport` change, and `lastSyncAt` stays: it is the time of
    /// the last sync of every watched repo.
    public func syncRepo(_ ref: RepoRef, viewers: ViewerLogins) async -> SyncReport? {
        guard auth == .ok, !hasEnded, !isSyncing, !isSyncingRepo, pass == nil else { return nil }
        if let until = rateLimitedUntil, now() < until { return nil }
        let generation = self.generation
        isSyncingRepo = true
        defer { isSyncingRepo = false }
        // Everything until now is in the snapshot.
        let snapshot = account
        journal = []
        var (synced, report) = await cancellable { [api, now] in
            await SyncEngine(api: api, now: now).sync(snapshot, repo: ref, viewers: viewers)
        }
        guard generation == self.generation else { return nil }
        await withholdUnconfirmedRejection(&report)
        guard generation == self.generation else { return nil }

        // Only this repo's state comes from the sync; the marks made on it meanwhile win.
        var merged = account
        merged.repos[ref.id] = synced.repos[ref.id]
        for mark in journal where mark.repo == ref.id { Self.apply(mark, to: &merged) }
        journal = []
        account = merged
        finishRepoSync(report, of: ref.id)
        return report
    }

    /// Records the result of a one-repo sync in `lastReport`: that repo's failure, the rate limit
    /// and a stop. The other repos' failures, the repo lists and owner issues stay. Saves.
    private func finishRepoSync(_ report: SyncReport, of repo: RepoID) {
        var last = lastReport ?? SyncReport()
        if lastReport == nil { last.availableRepos = account.available }
        last.repoFailures[repo] = report.repoFailures[repo]
        if let limit = report.rateLimit { last.rateLimit = limit }
        if let until = report.rateLimitedUntil {
            last.rateLimitedUntil = until
            rateLimitedUntil = until
            syncProblem = .rateLimited(until: until)
        }
        if report.needsReauth {
            last.needsReauth = true
            auth = .needsReauth
            // GitHub answered; the sign-in is the problem, shown by `auth`.
            syncProblem = nil
        }
        lastReport = last
        save()
    }

    /// Records the result of a pass and saves the account.
    private func finish(_ report: SyncReport, offline: Bool) {
        isSyncing = false
        lastReport = report
        // An offline pass that fell back to known owners is complete for those owners only.
        if report.isComplete, !offline { lastSyncAt = now() }
        rateLimitedUntil = report.rateLimitedUntil
        if let until = report.rateLimitedUntil {
            syncProblem = .rateLimited(until: until)
        } else if report.isComplete {
            // The repos synced from the previous owners, but GitHub was not reachable for the owners list.
            syncProblem = offline ? .offline : nil
        }
        if report.needsReauth {
            auth = .needsReauth
            // GitHub answered; the sign-in is the problem, shown by `auth`.
            syncProblem = nil
        }
        save()
    }

    /// Asks GitHub who the credential belongs to. True only when GitHub rejects it again; any other
    /// answer, including no answer, leaves the sign-in standing. Check `generation` afterwards.
    private func rejectionConfirmed() async -> Bool {
        let result: Result<Viewer, any Error> = await cancellable { [api] in
            do { return .success(try await api.viewer()) } catch { return .failure(error) }
        }
        if case .failure(let error) = result, case .unauthorized = error as? GitHubError { return true }
        return false
    }

    /// Turns a rejected sign-in that GitHub does not repeat into an unconfirmed one: the report
    /// stays incomplete, but `auth` is not touched. Check `generation` afterwards.
    private func withholdUnconfirmedRejection(_ report: inout SyncReport) async {
        guard report.needsReauth else { return }
        guard await rejectionConfirmed() else {
            report.needsReauth = false
            report.unconfirmedRejection = true
            return
        }
    }

    /// Runs `work` in its own task, which `end()` and a cancellation of the caller both cancel.
    private func cancellable<T: Sendable>(_ work: @escaping @Sendable () async -> T) async -> T {
        let task = Task(operation: work)
        cancelRunning = { task.cancel() }
        defer { cancelRunning = nil }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    // MARK: Watch config

    /// The item's description rendered to HTML. Does not touch the sync state.
    public func renderedBody(number: Int, in repo: RepoRef) async throws -> String? {
        try await api.renderedBody(number: number, in: repo)
    }

    /// Counts, metadata and period activity for the repo. Does not touch the sync state.
    public func insights(for repo: RepoRef, since: Date) async throws -> RepoInsights {
        try await api.insights(for: repo, since: since)
    }

    /// Assigns or unassigns the account's own login on GitHub; returns the resulting assignees.
    public func setAssigned(_ assigned: Bool, number: Int, in repo: RepoRef) async throws -> [String] {
        try await api.setAssigned(assigned, login: login, number: number, in: repo)
    }

    public func setOwnerMode(_ mode: OwnerMode, for owner: String) {
        account.watch.owners[owner] = mode
        save()
        onWatchChanged?()
    }

    /// Does not call `onWatchChanged`: notifications do not change what is synced.
    public func setNotifications(_ on: Bool, for repo: RepoID) {
        if on {
            account.watch.notificationsOff.remove(repo)
        } else {
            account.watch.notificationsOff.insert(repo)
        }
        save()
    }

    public func setShowArchived(_ on: Bool) {
        account.watch.showArchived = on
        save()
        onWatchChanged?()
    }

    // MARK: Marks

    public func markSeen(_ key: ItemKey) {
        guard let record = record(for: key) else { return }
        perform([.seen(key, version: record.item.updatedAt)])
    }

    public func markUnseen(_ key: ItemKey) {
        guard record(for: key) != nil else { return }
        perform([.unseen(key)])
    }

    /// Stores the assignees GitHub reported. Leaves attention alone; survives a running pass.
    public func setAssignees(_ logins: [String], for key: ItemKey) {
        guard record(for: key) != nil else { return }
        perform([.assignees(key, logins)])
    }

    public func markRepoSeen(_ repo: RepoID) {
        perform(Self.seenMarks(for: account.repos[repo].map { [$0] } ?? []))
    }

    public func markAllSeen() {
        perform(Self.seenMarks(for: Array(account.repos.values)))
    }

    private func record(for key: ItemKey) -> ItemRecord? {
        account.repos[key.repo]?.records[key.number]
    }

    private func perform(_ marks: [Mark]) {
        guard !marks.isEmpty else { return }
        var updated = account
        for mark in marks { Self.apply(mark, to: &updated) }
        account = updated
        if isSyncing || isSyncingRepo { journal += marks }
        save()
    }

    /// New and updated records (only listed records have that attention).
    private static func seenMarks(for states: [RepoState]) -> [Mark] {
        states.flatMap { state in
            state.records.values
                .filter { $0.attention != .seen }
                .map { Mark.seen($0.item.key, version: $0.item.updatedAt) }
        }
    }

    private static func apply(_ mark: Mark, to account: inout AccountData) {
        switch mark {
        case .seen(let key, let version):
            // Seen at server time. A record that changed since the user marked it (a sync fetched a
            // newer version) keeps what the sync found. Unknown keys (repo dropped) are ignored.
            guard let record = account.repos[key.repo]?.records[key.number], record.item.updatedAt == version else { return }
            account.repos[key.repo]?.records[key.number] = ItemStateEngine.markSeen(record, at: record.item.updatedAt)
        case .unseen(let key):
            guard let record = account.repos[key.repo]?.records[key.number] else { return }
            account.repos[key.repo]?.records[key.number] = ItemStateEngine.markUnseen(record)
        case .assignees(let key, let logins):
            account.repos[key.repo]?.records[key.number]?.item.assignees = logins
        }
    }

    // MARK: Persistence

    private func save() {
        do {
            try store.saveAccount(account)
        } catch {
            Self.log.error("Saving the account failed: \(error.localizedDescription, privacy: .public)")
        }
        onSaved?()
    }
}

/// The API of a session without a credential: GitHub would reject every call.
private struct RejectingAPI: GitHubAPI {
    func viewer() async throws -> Viewer { throw GitHubError.unauthorized }
    func owners() async throws -> [OwnerRef] { throw GitHubError.unauthorized }
    func repositories(of owner: OwnerRef) async throws -> Fetch<[RepoListing]> { throw GitHubError.unauthorized }
    func items(in repo: RepoRef, query: IssueQuery) async throws -> Fetch<[Item]> { throw GitHubError.unauthorized }
    func openPullDetails(in repo: RepoRef) async throws -> Fetch<[Int: PullDetails]> { throw GitHubError.unauthorized }
    func hasOtherActivity(on item: Item, in repo: RepoRef, since: Date, viewers: ViewerLogins) async throws -> Bool {
        throw GitHubError.unauthorized
    }
    func renderedBody(number: Int, in repo: RepoRef) async throws -> String? { throw GitHubError.unauthorized }
    func setAssigned(_ assigned: Bool, login: String, number: Int, in repo: RepoRef) async throws -> [String] {
        throw GitHubError.unauthorized
    }
    func insights(for repo: RepoRef, since: Date) async throws -> RepoInsights { throw GitHubError.unauthorized }
    func rateLimit() async -> RateLimit? { nil }
    func forgetConditionalState(for repo: RepoRef) async {}
}
