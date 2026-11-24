import Foundation
import Observation
import os

public enum AuthState: Sendable, Equatable {
    case signedOut, signedIn(login: String), needsReauth(login: String)
}

/// The app's single source of truth: session, settings, watched data and sync.
@MainActor @Observable
public final class RadarixController {
    public private(set) var auth: AuthState = .signedOut
    public private(set) var settings: AppSettings
    public private(set) var account: AccountData?
    public private(set) var credentialKind: CredentialKind?
    public private(set) var availableRepos: [String: [RepoRef]] = [:]
    public private(set) var owners: [OwnerRef] = []
    public private(set) var lastReport: SyncReport?
    public private(set) var lastSyncAt: Date?
    public private(set) var isSyncing = false
    /// Called after every sync that completed for the current session.
    @ObservationIgnored public var onSyncReport: ((SyncReport) -> Void)?

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
        guard let id = settings.lastAccountID, let credential = try? credentials.load(for: id) else { return }
        guard let stored = try? store.loadAccount(id) else {
            // No (readable) account file: sign in with the stored credential; on failure stay signed out.
            try? await signIn(token: credential.token, kind: credential.kind)
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
        settings.lastAccountID = viewer.id
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

    /// Deletes the credential; the account file and `lastAccountID` stay.
    public func signOut() throws {
        if let id = account?.accountID { try credentials.delete(for: id) }
        end()
    }

    /// Deletes the credential and every file.
    public func resetAllData() throws {
        for id in Set([account?.accountID, settings.lastAccountID].compactMap { $0 }) {
            try credentials.delete(for: id)
        }
        try store.resetAll()
        end()
        settings = AppSettings()
    }

    private func begin(api: GitHubAPI, account: AccountData, kind: CredentialKind) {
        end()
        self.api = api
        self.account = account
        credentialKind = kind
        auth = .signedIn(login: account.login)
        if schedulerEnabled { launchScheduler() }
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
        availableRepos = [:]
        lastReport = nil
        lastSyncAt = nil
        rateLimitedUntil = nil
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
        do {
            fetchedOwners = try await api.owners()
        } catch {
            guard session == self.session else { return false }
            switch error as? GitHubError {
            case .unauthorized:
                if let account { auth = .needsReauth(login: account.login) }
                return true
            case .rateLimited(let resetAt):
                rateLimitedUntil = resetAt
                return true
            default:
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
        let (synced, report) = await engine.sync(snapshot, owners: fetchedOwners, previousAvailable: availableRepos)
        guard session == self.session, let current = account else { return false }

        // Changes made during the sync win over the snapshot the engine worked on.
        var merged = synced
        merged.watch = current.watch
        for mark in journal { Self.apply(mark, to: &merged) }
        journal = []

        account = merged
        availableRepos = report.availableRepos
        lastReport = report
        lastSyncAt = now()
        rateLimitedUntil = report.rateLimitedUntil
        if report.needsReauth { auth = .needsReauth(login: merged.login) }
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
    }

    private func saveSettings() {
        do {
            try store.saveSettings(settings)
        } catch {
            Self.log.error("Saving the settings failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
