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

/// The app's single source of truth: settings, the account session, scheduling and the widget snapshot.
@MainActor @Observable
public final class RadarixController {
    public var auth: AuthState {
        guard let session else { return .signedOut }
        return switch session.auth {
        case .ok: .signedIn(login: session.login)
        case .needsReauth: .needsReauth(login: session.login)
        }
    }
    public private(set) var settings: AppSettings
    public var account: AccountData? { session?.account }
    public var credentialKind: CredentialKind? { session?.credentialKind }
    /// Repo lists of the account's active owners from the last sync, keyed by owner login.
    public var availableRepos: [String: [RepoRef]] { account?.available ?? [:] }
    public var owners: [OwnerRef] { session?.owners ?? [] }
    public var lastReport: SyncReport? { session?.lastReport }
    /// When the last sync that processed every watched repo finished.
    public var lastSyncAt: Date? { session?.lastSyncAt }
    public private(set) var isSyncing = false
    /// Set when the last sync attempt hit a problem; cleared by a completed sync.
    public var syncProblem: SyncProblem? { session?.syncProblem }
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

    /// The signed-in account; a sync of a session that ended meanwhile is discarded.
    private var session: AccountSession?
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
        begin(api: makeAPI(credential.token), account: stored, credential: credential)
        await refresh()
    }

    /// Validates the token, keeps any stored data of that account, then syncs.
    public func signIn(token: String, kind: CredentialKind) async throws {
        let api = makeAPI(token)
        let viewer = try await api.viewer()
        var loaded = try store.loadAccount(viewer.id) ?? AccountData(accountID: viewer.id, login: viewer.login)
        loaded.login = viewer.login
        try store.saveAccount(loaded)
        let credential = Credential(token: token, kind: kind)
        try credentials.save(credential, for: viewer.id)
        settings.accountIDs = [viewer.id]
        saveSettings()
        begin(api: api, account: loaded, credential: credential)
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
        if let id = session?.accountID { try credentials.delete(for: id) }
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

    private func begin(api: GitHubAPI, account: AccountData, credential: Credential) {
        end()
        // The widget keeps showing how old its data is, also after a relaunch.
        carriedSyncedAt = (try? store.loadSnapshot()).flatMap { previous in
            previous.login?.caseInsensitiveCompare(account.login) == .orderedSame ? previous.syncedAt : nil
        }
        let session = AccountSession(account: account, credential: credential, api: api, store: store, now: now)
        session.onSaved = { [weak self] in self?.writeSnapshot() }
        session.onWatchChanged = { [weak self] in self?.requestRefresh() }
        self.session = session
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
        session?.end()
        session = nil
        carriedSyncedAt = nil
    }

    // MARK: Sync

    /// Syncs once. Does nothing while syncing, when not signed in, or before a rate limit resets.
    public func refresh() async {
        guard !isSyncing, let session, session.auth == .ok else { return }
        if let until = session.rateLimitedUntil, now() < until { return }
        isSyncing = true
        let completed = await sync(session)
        isSyncing = false
        if followUpRefresh || (!completed && auth != .signedOut) {
            followUpRefresh = false
            requestRefresh()
        }
    }

    /// Repeats `refresh()` every `settings.refreshInterval` while signed in.
    public func startScheduler() {
        schedulerEnabled = true
        if scheduler == nil, session != nil { launchScheduler() }
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

    /// Returns false when the session ended meanwhile and the result was discarded.
    private func sync(_ session: AccountSession) async -> Bool {
        // The pass reads the watch config from here on.
        followUpRefresh = false
        let proceeds = await session.resolve()
        guard session === self.session else { return false }
        let report: SyncReport
        if proceeds {
            let keep = RepoResolver.stored(in: session.account, ownedBy: session.unknownOwners)
            guard let synced = await session.syncItems(
                owned: session.watchedRepos(), keep: keep, viewers: ViewerLogins([session.login])),
                session === self.session
            else { return false }
            report = synced
        } else if let stopped = session.stoppedReport {
            report = stopped
        } else {
            // The owners call failed; a rejected sign-in changes what the widget shows.
            writeSnapshot()
            return true
        }
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
        session?.setOwnerMode(mode, for: owner)
    }

    public func setNotifications(_ on: Bool, for repo: RepoID) {
        session?.setNotifications(on, for: repo)
    }

    public func setShowArchived(_ on: Bool) {
        session?.setShowArchived(on)
    }

    // MARK: Marks

    public func markSeen(_ key: ItemKey) {
        session?.markSeen(key)
    }

    public func markUnseen(_ key: ItemKey) {
        session?.markUnseen(key)
    }

    public func markRepoSeen(_ repo: RepoID) {
        session?.markRepoSeen(repo)
    }

    public func markAllSeen() {
        session?.markAllSeen()
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
