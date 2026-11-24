import Foundation

public enum SyncFailure: Sendable, Equatable {
    case network(String), notFound, http(Int), decoding(String)
}

public struct SyncReport: Sendable, Equatable {
    /// Became `.new` in this sync (never on baseline).
    public var newItems: [Item] = []
    /// Became `.updated` in this sync.
    public var updatedItems: [Item] = []
    public var repoFailures: [RepoID: SyncFailure] = [:]
    public var ownerIssues: [String: OwnerAccessIssue] = [:]
    public var needsReauth = false
    public var rateLimitedUntil: Date?
    public var rateLimit: RateLimit?
    /// Repo lists of every owner not in `.off` mode, keyed by owner login.
    public var availableRepos: [String: [RepoRef]] = [:]

    public init() {}
}

/// One sync pass over an account's watched repos. Stateless: everything it needs comes in,
/// everything it learned goes out.
public struct SyncEngine: Sendable {
    /// Look-back for repos without a high-water mark, against clock skew between this Mac and GitHub.
    static let overlap: TimeInterval = 300

    private let api: GitHubAPI
    private let now: @Sendable () -> Date

    public init(api: GitHubAPI, now: @Sendable @escaping () -> Date = Date.init) {
        self.api = api
        self.now = now
    }

    /// `previousAvailable` is the `availableRepos` of the previous report; it answers a repo list
    /// that is `.notModified` or could not be fetched.
    public func sync(
        _ account: AccountData, owners: [OwnerRef], previousAvailable: [String: [RepoRef]]
    ) async -> (AccountData, SyncReport) {
        var result = account
        var report = SyncReport()
        let active = owners.filter { (account.watch.owners[$0.login] ?? .off) != .off }
        var available = previousAvailable.filter { entry in active.contains { $0.login == entry.key } }

        do {
            for owner in active {
                do {
                    if case .fresh(let repos) = try await api.repositories(of: owner) {
                        available[owner.login] = repos
                    }
                } catch {
                    if let stop = Stop(error) { throw stop }
                    if owner.kind == .organization, case GitHubError.forbidden(let message) = error {
                        report.ownerIssues[owner.login] = .restricted(message: message)
                    }
                    // Any other failure keeps the previous list.
                }
            }

            let watched = RepoResolver.watched(config: account.watch, available: available)
            let watchedIDs = Set(watched.map(\.id))
            // Owners whose list is unknown (failed, no previous list) keep their repos' state untouched.
            let unknownOwners = Set(active.map(\.login)).subtracting(available.keys)
            result.repos = result.repos.filter { watchedIDs.contains($0.key) || unknownOwners.contains($0.value.repo.owner) }

            for ref in watched {
                try await syncRepo(ref, into: &result, report: &report)
            }
        } catch let stop as Stop {
            switch stop {
            case .reauth: report.needsReauth = true
            case .rateLimited(let resetAt): report.rateLimitedUntil = resetAt
            case .cancelled: break
            }
        } catch {
            // `Stop` is the only error that leaves the loops.
        }

        report.availableRepos = available
        report.rateLimit = await api.rateLimit()
        return (result, report)
    }

    // MARK: Per repo

    /// Collected while processing one repo and only reported once that repo's items are committed.
    private struct Changes {
        var new: [Int] = []
        var updated: [Int] = []
    }

    private func syncRepo(_ ref: RepoRef, into account: inout AccountData, report: inout SyncReport) async throws {
        var state = account.repos[ref.id] ?? RepoState(repo: ref)
        state.repo = ref
        var changes = Changes()
        do {
            // Work on a copy: a stop in the middle of the items leaves this repo as it was.
            var updated = state
            var found = Changes()
            if updated.baselineAt == nil {
                try await baseline(&updated)
            } else {
                try await fetchChanges(&updated, viewer: account.login, changes: &found)
            }
            updated.lastFailure = nil
            state = updated
            changes = found
            // Commit before the pulls request, so a failure there cannot discard item changes
            // that the next (identical, conditional) items request would answer with 304.
            account.repos[ref.id] = state
            try await mergePullDetails(&state)
        } catch {
            if let stop = Stop(error) {
                // Items committed before the stop are reported with the committed state.
                Self.report(changes, of: account.repos[ref.id], into: &report)
                throw stop
            }
            let failure = Self.failure(for: error)
            report.repoFailures[ref.id] = failure
            state.lastFailure = String(describing: failure)
        }
        account.repos[ref.id] = state
        Self.report(changes, of: state, into: &report)
    }

    private static func report(_ changes: Changes, of state: RepoState?, into report: inout SyncReport) {
        guard let state else { return }
        report.newItems += changes.new.compactMap { state.records[$0]?.item }
        report.updatedItems += changes.updated.compactMap { state.records[$0]?.item }
    }

    private func baseline(_ state: inout RepoState) async throws {
        guard case .fresh(let items) = try await api.items(in: state.repo, query: .openForBaseline) else {
            // Nothing to baseline from; `baselineAt` stays nil and the next sync tries again.
            return
        }
        let newest = items.map(\.updatedAt).max()
        state.records = [:]
        if let newest {
            for record in ItemStateEngine.baseline(items, at: newest) {
                state.records[record.item.key.number] = record
            }
        }
        state.baselineAt = now()
        state.highWaterMark = newest
    }

    private func fetchChanges(_ state: inout RepoState, viewer: String, changes: inout Changes) async throws {
        guard let baselineAt = state.baselineAt else { return }
        // Exactly the stored mark, so the URL (and its ETag) stays the same until something changes.
        let since = state.highWaterMark ?? baselineAt.addingTimeInterval(-Self.overlap)
        guard case .fresh(let items) = try await api.items(in: state.repo, query: .changed(since: since)) else { return }

        for item in items {
            let stored = state.records[item.key.number]
            // `since` is inclusive: the item that set the mark comes back every time.
            if let stored, stored.item.updatedAt == item.updatedAt { continue }

            var previous = stored
            if previous == nil, item.createdAt < baselineAt {
                // Existed before the repo was watched (e.g. reopened): never new.
                previous = ItemRecord(item: item, attention: .seen, seenAt: since, commentsAtSeen: 0)
            }

            var otherActivity: Bool?
            if ItemStateEngine.needsActivityCheck(previous: previous, fetched: item), let seenAt = previous?.seenAt {
                do {
                    otherActivity = try await api.hasOtherActivity(on: item, in: state.repo, since: seenAt, viewer: viewer)
                } catch {
                    if let stop = Stop(error) { throw stop }
                    otherActivity = nil
                }
            }

            var record = ItemStateEngine.apply(fetched: item, previous: previous, viewer: viewer, otherActivity: otherActivity)
            if let stored {
                // The issues endpoint carries no PR details; keep the last known ones.
                record.item.isDraft = stored.item.isDraft
                record.item.requestedReviewers = stored.item.requestedReviewers
            }
            state.records[item.key.number] = record

            if record.attention == .new, stored?.attention != .new { changes.new.append(item.key.number) }
            if record.attention == .updated, stored?.attention != .updated { changes.updated.append(item.key.number) }
        }

        if let newest = items.map(\.updatedAt).max() {
            state.highWaterMark = max(state.highWaterMark ?? newest, newest)
        }
    }

    private func mergePullDetails(_ state: inout RepoState) async throws {
        guard case .fresh(let details) = try await api.openPullDetails(in: state.repo) else { return }
        for (number, var record) in state.records where record.item.kind == .pullRequest && record.item.status == .open {
            let pull = details[number]
            record.item.isDraft = pull?.isDraft ?? false
            record.item.requestedReviewers = pull?.requestedReviewers ?? []
            state.records[number] = record
        }
    }

    // MARK: Errors

    /// Errors that end the whole sync.
    private enum Stop: Error {
        case reauth
        case rateLimited(Date)
        case cancelled

        init?(_ error: Error) {
            if let stop = error as? Stop {
                self = stop
                return
            }
            if error is CancellationError {
                self = .cancelled
                return
            }
            switch error as? GitHubError {
            case .unauthorized: self = .reauth
            case .rateLimited(let resetAt): self = .rateLimited(resetAt)
            default: return nil
            }
        }
    }

    private static func failure(for error: Error) -> SyncFailure {
        switch error as? GitHubError {
        case .network(let message): .network(message)
        case .notFound: .notFound
        case .http(let code): .http(code)
        case .decoding(let message): .decoding(message)
        case .forbidden: .http(403)
        // Handled as `Stop` before this point.
        case .unauthorized: .http(401)
        case .rateLimited: .http(429)
        case nil: .network(String(describing: error))
        }
    }
}
