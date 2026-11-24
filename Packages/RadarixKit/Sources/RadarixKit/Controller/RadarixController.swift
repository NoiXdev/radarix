import Foundation
import Observation
import os

public enum AuthState: Sendable, Equatable {
    case signedOut, signedIn(login: String), needsReauth(login: String)
}

/// Why the last sync attempt could not run fully. Repo failures are in `SyncReport.repoFailures`.
public enum SyncProblem: Sendable, Equatable {
    /// GitHub could not be reached; stored data is shown.
    case offline
    /// No sync before this time.
    case rateLimited(until: Date)
}

/// The app's single source of truth: session, settings, watched data and sync.
@MainActor @Observable
public final class RadarixController {
    public private(set) var auth: AuthState = .signedOut
    public private(set) var settings: AppSettings
    public private(set) var account: AccountData?
    public private(set) var credentialKind: CredentialKind?
    /// Repo lists of the account's active owners from the last sync, keyed by owner login.
    public var availableRepos: [String: [RepoRef]] { account?.available ?? [:] }
    public private(set) var owners: [OwnerRef] = []
    public private(set) var lastReport: SyncReport?
    /// When the last sync that processed every watched repo finished.
    public private(set) var lastSyncAt: Date?
    public private(set) var isSyncing = false
    /// Set when the last sync attempt hit a problem; cleared by a completed sync.
    public private(set) var syncProblem: SyncProblem?
    /// Called after every sync that completed for the current session.
    @ObservationIgnored public var onSyncReport: ((SyncReport) -> Void)?
    /// Called when the widget should reload: the snapshot was removed, or what it shows changed,
    /// or its `syncedAt` moved `snapshotReloadAge` past the one of the last call.
    @ObservationIgnored public var onSnapshotWritten: (() -> Void)?

    /// A sync time this much newer than the widget's is worth a reload: half of
    /// `WidgetSnapshot.staleAfter`, so a widget of a syncing app never shows its data as stale.
    public static let snapshotReloadAge: TimeInterval = WidgetSnapshot.staleAfter / 2

    /// The refresh started by the last watch change.
    @ObservationIgnored var pendingRefresh: Task<Void, Never>?

    private let store: FileStore
    private let credentials: CredentialStore
    private let makeAPI: @Sendable (String) -> GitHubAPI
    private let oauthClientID: String
    private let now: @Sendable () -> Date

    /// Built once per credential.
    @ObservationIgnored private var api: GitHubAPI?
    @ObservationIgnored private var rateLimitedUntil: Date?
    /// Changes whenever a session begins or ends; a sync from another session is discarded.
    @ObservationIgnored private var session = 0
    /// Marks made while a sync runs, re-applied to its result.
    @ObservationIgnored private var journal: [Mark] = []
    /// A watch change arrived after the running sync took its snapshot.
    @ObservationIgnored private var followUpRefresh = false
    /// `pendingRefresh` was started but has not begun its refresh yet.
    @ObservationIgnored private var refreshQueued = false
    @ObservationIgnored private var scheduler: Task<Void, Never>?
    @ObservationIgnored private var schedulerEnabled = false
    /// The snapshot last saved by this controller; nil before the first write and after a reset.
    @ObservationIgnored private var writtenSnapshot: WidgetSnapshot?
    /// The `syncedAt` of the snapshot at the last `onSnapshotWritten` call.
    @ObservationIgnored private var reloadedSyncedAt: Date?
    /// The previous launch's sync time of this account, from the snapshot file, until a sync completes.
    @ObservationIgnored private var carriedSyncedAt: Date?

    private static let log = Logger(subsystem: "dev.noix.radarix", category: "controller")

    private enum Mark {
        /// `version` is the `updatedAt` of the record the user marked.
        case seen(ItemKey, version: Date)
        case unseen(ItemKey)
    }

    public init(
        store: FileStore, credentials: CredentialStore, makeAPI: @escaping @Sendable (String) -> GitHubAPI,
        oauthClientID: String, now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.store = store
        self.credentials = credentials
        self.makeAPI = makeAPI
        self.oauthClientID = oauthClientID
        self.now = now
        // A corrupt settings file falls back to defaults (known v1 limitation).
        settings = (try? store.loadSettings()) ?? AppSettings()
    }

    // MARK: Session

    /// Loads the last account and its credential, then syncs. Stored data is shown even when offline.
    public func restoreSession() async {
        guard let id = settings.accountIDs.first, let credential = try? credentials.load(for: id) else {
            writeSnapshot()
            return
        }
        guard let stored = try? store.loadAccount(id) else {
            // No (readable) account file: sign in with the stored credential; on failure stay signed out.
            do { try await signIn(token: credential.token, kind: credential.kind) } catch { writeSnapshot() }
            return
        }
        begin(api: makeAPI(credential.token), account: stored, kind: credential.kind)
        await refresh()
    }

    /// Validates the token, keeps any stored data of that account, then syncs.
    public func signIn(token: String, kind: CredentialKind) async throws {
        let api = makeAPI(token)
        let viewer = try await api.viewer()
        var loaded = try store.loadAccount(viewer.id) ?? AccountData(accountID: viewer.id, login: viewer.login)
        loaded.login = viewer.login
        try store.saveAccount(loaded)
        try credentials.save(Credential(token: token, kind: kind), for: viewer.id)
        settings.accountIDs = [viewer.id]
        saveSettings()
        begin(api: api, account: loaded, kind: kind)
        await refresh()
    }

    public func startDeviceFlow() async throws -> DeviceCode {
        try await DeviceFlow(clientID: oauthClientID).start()
    }

    public func completeDeviceFlow(_ code: DeviceCode) async throws {
        let token = try await DeviceFlow(clientID: oauthClientID).waitForToken(code)
        try await signIn(token: token, kind: .oauth)
    }

    /// Deletes the credential; the account file and `accountIDs` stay.
    public func signOut() throws {
        if let id = account?.accountID { try credentials.delete(for: id) }
        end()
        writeSnapshot()
    }

    /// Deletes the credential and every file, the widget snapshot included.
    public func resetAllData() throws {
        try credentials.deleteAll()
        do {
            try store.resetAll()
        } catch {
            // Without a credential the session cannot go on, whatever files are left.
            end()
            writeSnapshot()
            throw error
        }
        end()
        settings = AppSettings()
        writtenSnapshot = nil
        reloadedSyncedAt = nil
        // No snapshot is written after the wipe; the widget reloads into its signed-out state.
        onSnapshotWritten?()
    }

    private func begin(api: GitHubAPI, account: AccountData, kind: CredentialKind) {
        end()
        // The widget keeps showing how old its data is, also after a relaunch.
        carriedSyncedAt = (try? store.loadSnapshot()).flatMap { previous in
            previous.login?.caseInsensitiveCompare(account.login) == .orderedSame ? previous.syncedAt : nil
        }
        self.api = api
        self.account = account
        credentialKind = kind
        auth = .signedIn(login: account.login)
        if schedulerEnabled { launchScheduler() }
        writeSnapshot()
    }

    private func end() {
        scheduler?.cancel()
        scheduler = nil
        pendingRefresh?.cancel()
        pendingRefresh = nil
        refreshQueued = false
        followUpRefresh = false
        session += 1
        api = nil
        auth = .signedOut
        account = nil
        credentialKind = nil
        owners = []
        lastReport = nil
        lastSyncAt = nil
        carriedSyncedAt = nil
        rateLimitedUntil = nil
        syncProblem = nil
        journal = []
    }

    // MARK: Sync

    /// Syncs once. Does nothing while syncing, when not signed in, or before a rate limit resets.
    public func refresh() async {
        guard !isSyncing, case .signedIn = auth, let api else { return }
        if let until = rateLimitedUntil, now() < until { return }
        let session = self.session
        isSyncing = true
        let completed = await sync(api, session: session)
        isSyncing = false
        if followUpRefresh || (!completed && auth != .signedOut) {
            followUpRefresh = false
            requestRefresh()
        }
    }

    /// Repeats `refresh()` every `settings.refreshInterval` while signed in.
    public func startScheduler() {
        schedulerEnabled = true
        if scheduler == nil, account != nil { launchScheduler() }
    }

    private func launchScheduler() {
        scheduler?.cancel()
        scheduler = Task { [weak self] in
            while let interval = self?.settings.refreshInterval {
                do { try await Task.sleep(for: .seconds(interval)) } catch { return }
                await self?.refresh()
            }
        }
    }

    /// Starts a refresh now, or right after the running one.
    private func requestRefresh() {
        if isSyncing || refreshQueued {
            followUpRefresh = true
            return
        }
        refreshQueued = true
        pendingRefresh = Task {
            refreshQueued = false
            await refresh()
        }
    }

    /// Returns false when the session changed meanwhile and the result was discarded.
    private func sync(_ api: GitHubAPI, session: Int) async -> Bool {
        let fetchedOwners: [OwnerRef]
        var offline = false
        do {
            fetchedOwners = try await api.owners()
        } catch {
            guard session == self.session else { return false }
            switch error as? GitHubError {
            case .unauthorized:
                if let account { auth = .needsReauth(login: account.login) }
                // GitHub answered; the sign-in is the problem, shown by `auth`.
                syncProblem = nil
                writeSnapshot()
                return true
            case .rateLimited(let resetAt):
                rateLimitedUntil = resetAt
                syncProblem = .rateLimited(until: resetAt)
                return true
            default:
                if case .network = error as? GitHubError {
                    offline = true
                    syncProblem = .offline
                }
                // Keep the previous owners; without any, try again next time.
                guard !owners.isEmpty else { return true }
                fetchedOwners = owners
            }
        }
        guard session == self.session, let snapshot = account else { return false }
        owners = fetchedOwners
        // Everything until now is in the snapshot.
        journal = []
        followUpRefresh = false

        let engine = SyncEngine(api: api, now: now)
        let resolution = await engine.resolve(snapshot, owners: fetchedOwners)
        var synced = snapshot
        var report = SyncReport()
        if let stop = resolution.stop {
            // Nothing was synced yet: the account stays as it was.
            report.record(stop)
            report.rateLimit = await api.rateLimit()
        } else {
            let owned = RepoResolver.watched(config: snapshot.watch, available: resolution.available)
            // Owners whose list is unknown (failed, no previous list) keep their repos' state untouched.
            let keep = Set(snapshot.repos.values.filter { resolution.unknownOwners.contains($0.repo.owner) }.map(\.repo.id))
            (synced, report) = await engine.sync(snapshot, owned: owned, keep: keep, viewers: ViewerLogins([snapshot.login]))
        }
        report.availableRepos = resolution.available
        report.ownerIssues = resolution.ownerIssues
        guard session == self.session, let current = account else { return false }

        // Changes made during the sync win over the snapshot the engine worked on.
        var merged = synced
        merged.watch = current.watch
        merged.available = resolution.available
        for mark in journal { Self.apply(mark, to: &merged) }
        journal = []

        account = merged
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
            auth = .needsReauth(login: merged.login)
            // GitHub answered; the sign-in is the problem, shown by `auth`.
            syncProblem = nil
        }
        saveAccount()
        onSyncReport?(report)
        return true
    }

    // MARK: Settings and watch config

    public func updateSettings(_ change: (inout AppSettings) -> Void) {
        let interval = settings.refreshInterval
        change(&settings)
        saveSettings()
        if settings.refreshInterval != interval, scheduler != nil { launchScheduler() }
    }

    public func setOwnerMode(_ mode: OwnerMode, for owner: String) {
        guard account != nil else { return }
        account?.watch.owners[owner] = mode
        saveAccount()
        requestRefresh()
    }

    public func setNotifications(_ on: Bool, for repo: RepoID) {
        guard account != nil else { return }
        if on {
            account?.watch.notificationsOff.remove(repo)
        } else {
            account?.watch.notificationsOff.insert(repo)
        }
        saveAccount()
    }

    public func setShowArchived(_ on: Bool) {
        guard account != nil else { return }
        account?.watch.showArchived = on
        saveAccount()
        requestRefresh()
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

    public func markRepoSeen(_ repo: RepoID) {
        perform(Self.seenMarks(for: account?.repos[repo].map { [$0] } ?? []))
    }

    public func markAllSeen() {
        perform(Self.seenMarks(for: account.map { Array($0.repos.values) } ?? []))
    }

    private func record(for key: ItemKey) -> ItemRecord? {
        account?.repos[key.repo]?.records[key.number]
    }

    private func perform(_ marks: [Mark]) {
        guard var updated = account, !marks.isEmpty else { return }
        for mark in marks { Self.apply(mark, to: &updated) }
        account = updated
        if isSyncing { journal += marks }
        saveAccount()
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
        }
    }

    // MARK: Queries

    /// Records of one repo, or of every watched repo for nil. Unfiltered and unsorted.
    public func records(in repo: RepoID?) -> [ItemRecord] {
        guard let account else { return [] }
        if let repo { return account.repos[repo].map { Array($0.records.values) } ?? [] }
        return account.repos.values.flatMap { $0.records.values }
    }

    public func counts(in repo: RepoID?) -> AttentionCounts {
        ItemFilter.counts(records(in: repo), bots: settings.botDisplay)
    }

    // MARK: Persistence

    private func saveAccount() {
        guard let account else { return }
        do {
            try store.saveAccount(account)
        } catch {
            Self.log.error("Saving the account failed: \(error.localizedDescription, privacy: .public)")
        }
        writeSnapshot()
    }

    private func saveSettings() {
        do {
            try store.saveSettings(settings)
        } catch {
            Self.log.error("Saving the settings failed: \(error.localizedDescription, privacy: .public)")
        }
        writeSnapshot()
    }

    /// The widget's view of the session: `.signedOut` without an account. Saved when it differs
    /// from the last one; the widget reloads only when `needsReload` says so, to stay within its budget.
    private func writeSnapshot() {
        let snapshot = if let account, auth != .signedOut {
            WidgetSnapshot.make(
                account: account, settings: settings, auth: auth, syncedAt: lastSyncAt ?? carriedSyncedAt)
        } else {
            WidgetSnapshot.signedOut
        }
        guard snapshot != writtenSnapshot else { return }
        do {
            try store.saveSnapshot(snapshot)
        } catch {
            Self.log.error("Saving the widget snapshot failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        let previous = writtenSnapshot
        writtenSnapshot = snapshot
        guard Self.needsReload(snapshot, previous: previous, reloadedSyncedAt: reloadedSyncedAt) else { return }
        reloadedSyncedAt = snapshot.syncedAt
        onSnapshotWritten?()
    }

    /// True for the first write, for changed content, and for a `syncedAt` that appeared, went away
    /// or is `snapshotReloadAge` newer than the widget's.
    private static func needsReload(_ snapshot: WidgetSnapshot, previous: WidgetSnapshot?, reloadedSyncedAt: Date?) -> Bool {
        guard let previous else { return true }
        var sameTime = snapshot
        sameTime.syncedAt = previous.syncedAt
        if sameTime != previous { return true }
        switch (snapshot.syncedAt, reloadedSyncedAt) {
        case (nil, nil): return false
        case (let syncedAt?, let reloaded?): return syncedAt.timeIntervalSince(reloaded) >= snapshotReloadAge
        default: return true
        }
    }
}
