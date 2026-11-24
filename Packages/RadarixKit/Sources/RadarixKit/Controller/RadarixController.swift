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

/// The app's single source of truth: settings, one session per signed-in account, repo ownership,
/// scheduling and the widget snapshot.
///
/// Every repo is synced by one account, its owner: the earliest account in `settings.accountIDs`
/// whose watch configuration includes it, computed from each account's persisted repo lists so an
/// unhealthy account keeps its repos.
@MainActor @Observable
public final class RadarixController {
    public private(set) var settings: AppSettings
    /// One per account in `settings.accountIDs` whose credential loaded, in that order.
    public private(set) var sessions: [AccountSession] = []
    /// Repo id to owning account, from the last sync pass.
    public private(set) var ownership: [RepoID: AccountID] = [:]
    /// Called after every sync of a session that completed, with that session's account.
    @ObservationIgnored public var onSyncReport: ((AccountData, SyncReport) -> Void)?
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

    /// A sync pass is running.
    @ObservationIgnored private var passRunning = false
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
    /// The previous launch's sync time, from the snapshot file, for the account it names.
    @ObservationIgnored private var carriedSyncedAt: (login: String, date: Date)?

    private static let log = Logger(subsystem: "dev.noix.radarix", category: "controller")

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

    // MARK: Workspace state

    public var isSignedIn: Bool { !sessions.isEmpty }
    public var isSyncing: Bool { sessions.contains { $0.isSyncing } }
    public var needsReauth: [AccountSession] { sessions.filter { $0.auth == .needsReauth } }
    /// The logins of every account: who counts as "me".
    public var viewers: ViewerLogins { ViewerLogins(sessions.map(\.login)) }

    /// The oldest `lastSyncAt` of the sessions that do not need reauth, or of all when every one
    /// does; nil without sessions or when one of those never completed a sync.
    public var lastSyncAt: Date? {
        let healthy = sessions.filter { $0.auth == .ok }
        let considered = healthy.isEmpty ? sessions : healthy
        guard !considered.isEmpty else { return nil }
        var oldest: Date?
        for session in considered {
            guard let date = session.lastSyncAt else { return nil }
            oldest = min(oldest ?? date, date)
        }
        return oldest
    }

    public func session(for id: AccountID) -> AccountSession? {
        sessions.first { $0.accountID == id }
    }

    /// The session whose state of `repo` is shown and marked: its owner, or for a repo without
    /// one (not yet computed, or a state kept for an owner whose repo list is unknown) the first
    /// session that has a state of it.
    public func owner(of repo: RepoID) -> AccountSession? {
        if let id = ownership[repo] { return session(for: id) }
        return sessions.first { $0.account.repos[repo] != nil }
    }

    /// The state of every repo, each from its owner.
    public var repos: [RepoID: RepoState] {
        var result: [RepoID: RepoState] = [:]
        for session in sessions {
            for (id, state) in session.account.repos where result[id] == nil && owner(of: id) === session {
                result[id] = state
            }
        }
        return result
    }

    // MARK: Accounts

    /// Builds a session for every account whose credential loads, writes the snapshot, then syncs.
    /// Stored data is shown even when offline. An account that cannot be restored stays in
    /// `settings.accountIDs`.
    public func restoreSessions() async {
        for id in settings.accountIDs where session(for: id) == nil {
            guard let credential = try? credentials.load(for: id) else { continue }
            let api = makeAPI(credential.token)
            if let stored = try? store.loadAccount(id) {
                insert(makeSession(account: stored, credential: credential, api: api))
                continue
            }
            // No (readable) account file: sign in with the stored credential; on failure skip it.
            do {
                let viewer = try await api.viewer()
                guard viewer.id == id else {
                    Self.log.error("The credential of account \(id.rawValue) belongs to another account")
                    continue
                }
                let account = try loadOrCreateAccount(viewer, existing: nil)
                guard session(for: id) == nil else { continue }
                insert(makeSession(account: account, credential: credential, api: api))
            } catch {
                Self.log.error("Restoring account \(id.rawValue) failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        writeSnapshot()
        await refresh()
    }

    /// Validates the token, keeps any stored data of that account, saves the credential, then syncs.
    /// A new account goes to the end of the list; one already in it gets the new credential.
    public func addAccount(token: String, kind: CredentialKind) async throws {
        let api = makeAPI(token)
        let viewer = try await api.viewer()
        let account = try loadOrCreateAccount(viewer, existing: session(for: viewer.id))
        let credential = Credential(token: token, kind: kind)
        try credentials.save(credential, for: viewer.id)
        if !settings.accountIDs.contains(viewer.id) { settings.accountIDs.append(viewer.id) }
        insert(makeSession(account: account, credential: credential, api: api))
        saveSettings()
        if passRunning {
            // The running pass started without this session.
            requestRefresh()
        } else {
            await refresh()
        }
    }

    public func startDeviceFlow() async throws -> DeviceCode {
        try await DeviceFlow(clientID: oauthClientID).start()
    }

    public func completeDeviceFlow(_ code: DeviceCode) async throws {
        let token = try await DeviceFlow(clientID: oauthClientID).waitForToken(code)
        try await addAccount(token: token, kind: .oauth)
    }

    /// Deletes the account's credential and drops it from the list; its account file stays, so
    /// adding it again resumes its settings and seen state. Another account may take over its repos.
    public func removeAccount(_ id: AccountID) throws {
        try credentials.delete(for: id)
        if let index = sessions.firstIndex(where: { $0.accountID == id }) {
            sessions[index].end()
            sessions.remove(at: index)
        }
        // Marks on its repos are dropped until the next pass assigns them.
        ownership = ownership.filter { $0.value != id }
        settings.accountIDs.removeAll { $0 == id }
        if sessions.isEmpty { stopWork() }
        saveSettings()
        if !sessions.isEmpty { requestRefresh() }
    }

    /// Deletes every credential and every file, the widget snapshot included.
    public func resetAllData() throws {
        try credentials.deleteAll()
        do {
            try store.resetAll()
        } catch {
            // Without credentials the sessions cannot go on, whatever files are left.
            endAll()
            writeSnapshot()
            throw error
        }
        endAll()
        settings = AppSettings()
        writtenSnapshot = nil
        reloadedSyncedAt = nil
        // No snapshot is written after the wipe; the widget reloads into its signed-out state.
        onSnapshotWritten?()
    }

    /// The stored account of `viewer` (or the running session's, which is at least as new), with
    /// the current login, saved; a new one when there is none.
    private func loadOrCreateAccount(_ viewer: Viewer, existing: AccountSession?) throws -> AccountData {
        var account = try existing?.account ?? store.loadAccount(viewer.id)
            ?? AccountData(accountID: viewer.id, login: viewer.login)
        account.login = viewer.login
        try store.saveAccount(account)
        return account
    }

    private func makeSession(account: AccountData, credential: Credential, api: GitHubAPI) -> AccountSession {
        let session = AccountSession(account: account, credential: credential, api: api, store: store, now: now)
        session.onSaved = { [weak self] in self?.accountSaved() }
        session.onWatchChanged = { [weak self] in self?.requestRefresh() }
        return session
    }

    /// Puts `session` in its place by `settings.accountIDs`, ending a session of the same account.
    private func insert(_ session: AccountSession) {
        let wasEmpty = sessions.isEmpty
        if let index = sessions.firstIndex(where: { $0.accountID == session.accountID }) {
            sessions[index].end()
            sessions[index] = session
        } else {
            let order = settings.accountIDs
            let rank = { (id: AccountID) in order.firstIndex(of: id) ?? order.count }
            let index = sessions.firstIndex { rank($0.accountID) > rank(session.accountID) } ?? sessions.endIndex
            sessions.insert(session, at: index)
        }
        guard wasEmpty else { return }
        // The widget keeps showing how old its data is, also after a relaunch.
        carriedSyncedAt = (try? store.loadSnapshot()).flatMap { previous in
            guard let login = previous.login, let date = previous.syncedAt else { return nil }
            return (login, date)
        }
        if schedulerEnabled { launchScheduler() }
    }

    private func endAll() {
        for session in sessions { session.end() }
        sessions = []
        ownership = [:]
        stopWork()
    }

    /// Without sessions nothing is scheduled.
    private func stopWork() {
        scheduler?.cancel()
        scheduler = nil
        pendingRefresh?.cancel()
        pendingRefresh = nil
        refreshQueued = false
        followUpRefresh = false
        carriedSyncedAt = nil
    }

    // MARK: Sync

    /// Syncs every account once. Does nothing while syncing or when signed out; an account that
    /// needs reauth or waits for a rate limit to reset skips the pass.
    public func refresh() async {
        guard !passRunning, !sessions.isEmpty else { return }
        passRunning = true
        let completed = await runPass()
        passRunning = false
        // Saves during the pass were left for this one write.
        writeSnapshot()
        if followUpRefresh || (!completed && !sessions.isEmpty) {
            followUpRefresh = false
            requestRefresh()
        }
    }

    /// Repeats `refresh()` every `settings.refreshInterval` while signed in.
    public func startScheduler() {
        schedulerEnabled = true
        if scheduler == nil, !sessions.isEmpty { launchScheduler() }
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
        if passRunning || refreshQueued {
            followUpRefresh = true
            return
        }
        refreshQueued = true
        pendingRefresh = Task {
            refreshQueued = false
            await refresh()
        }
    }

    /// Resolves every session in account order, assigns repo ownership, then syncs the items of
    /// every resolved session concurrently. Returns false when a session ended meanwhile and its
    /// result was discarded.
    private func runPass() async -> Bool {
        // The pass reads the watch config from here on.
        followUpRefresh = false
        let pass = sessions
        var resolved: [AccountSession] = []
        for session in pass where isCurrent(session) {
            if await session.resolve() { resolved.append(session) }
        }

        // Sessions that could not resolve keep their repos through their persisted lists.
        ownership = RepoOwnership.assign(sessions.map { ($0.accountID, $0.watchedRepos()) })
        let viewers = viewers
        let jobs = resolved.filter(isCurrent).map { session in
            let id = session.accountID
            let owned = session.watchedRepos().filter { ownership[$0.id] == id }
            let keep = RepoResolver.stored(in: session.account, ownedBy: session.unknownOwners)
                .filter { ownership[$0] == nil || ownership[$0] == id }
            return (session: session, owned: owned, keep: keep)
        }
        // Each resolved session must run its item phase, also when it owns nothing: that drops
        // the states of repos another account owns and ends its pass.
        let results = await withTaskGroup(of: (Int, SyncReport?).self) { group in
            for (index, job) in jobs.enumerated() {
                group.addTask {
                    (index, await job.session.syncItems(owned: job.owned, keep: job.keep, viewers: viewers))
                }
            }
            var results = [SyncReport?](repeating: nil, count: jobs.count)
            for await (index, report) in group { results[index] = report }
            return results
        }
        var synced: [ObjectIdentifier: SyncReport] = [:]
        for (job, report) in zip(jobs, results) {
            if let report { synced[ObjectIdentifier(job.session)] = report }
        }

        var completed = true
        for session in pass {
            guard isCurrent(session) else {
                completed = false
                continue
            }
            if resolved.contains(where: { $0 === session }) {
                guard let report = synced[ObjectIdentifier(session)] else {
                    completed = false
                    continue
                }
                onSyncReport?(session.account, report)
            } else if let stopped = session.stoppedReport {
                onSyncReport?(session.account, stopped)
            }
        }
        return completed
    }

    private func isCurrent(_ session: AccountSession) -> Bool {
        sessions.contains { $0 === session }
    }

    // MARK: Settings and watch config

    public func updateSettings(_ change: (inout AppSettings) -> Void) {
        let interval = settings.refreshInterval
        change(&settings)
        saveSettings()
        if settings.refreshInterval != interval, scheduler != nil { launchScheduler() }
    }

    public func setOwnerMode(_ mode: OwnerMode, for owner: String, in account: AccountID) {
        session(for: account)?.setOwnerMode(mode, for: owner)
    }

    public func setNotifications(_ on: Bool, for repo: RepoID, in account: AccountID) {
        session(for: account)?.setNotifications(on, for: repo)
    }

    public func setShowArchived(_ on: Bool, in account: AccountID) {
        session(for: account)?.setShowArchived(on)
    }

    // MARK: Marks

    /// Goes to the repo's owner; dropped when it has none.
    public func markSeen(_ key: ItemKey) {
        owner(of: key.repo)?.markSeen(key)
        writeSnapshot()
    }

    public func markUnseen(_ key: ItemKey) {
        owner(of: key.repo)?.markUnseen(key)
        writeSnapshot()
    }

    public func markRepoSeen(_ repo: RepoID) {
        owner(of: repo)?.markRepoSeen(repo)
        writeSnapshot()
    }

    public func markAllSeen() {
        for session in sessions { session.markAllSeen() }
        writeSnapshot()
    }

    // MARK: Queries

    /// Records of one repo, or of every watched repo for nil, each repo from its owner.
    /// Unfiltered and unsorted.
    public func records(in repo: RepoID?) -> [ItemRecord] {
        if let repo { return owner(of: repo)?.account.repos[repo].map { Array($0.records.values) } ?? [] }
        return repos.values.flatMap { $0.records.values }
    }

    public func counts(in repo: RepoID?) -> AttentionCounts {
        ItemFilter.counts(records(in: repo), bots: settings.botDisplay)
    }

    // MARK: Persistence

    private func saveSettings() {
        do {
            try store.saveSettings(settings)
        } catch {
            Self.log.error("Saving the settings failed: \(error.localizedDescription, privacy: .public)")
        }
        writeSnapshot()
    }

    /// Account saves during a pass are written once at its end.
    private func accountSaved() {
        if !passRunning { writeSnapshot() }
    }

    /// The widget's view of the first session (the merged view is to come): `.signedOut` without
    /// one. Saved when it differs from the last one; the widget reloads only when `needsReload`
    /// says so, to stay within its budget.
    private func writeSnapshot() {
        let snapshot = if let session = sessions.first {
            WidgetSnapshot.make(
                account: session.account, settings: settings,
                auth: session.auth == .ok ? .signedIn(login: session.login) : .needsReauth(login: session.login),
                syncedAt: session.lastSyncAt ?? carriedSyncedAt(for: session.login))
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

    private func carriedSyncedAt(for login: String) -> Date? {
        guard let carried = carriedSyncedAt, carried.login.caseInsensitiveCompare(login) == .orderedSame else { return nil }
        return carried.date
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
