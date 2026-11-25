import Foundation
@testable import RadarixKit

/// Scriptable `GitHubAPI` for sync tests.
///
/// Results are queued per owner login, repo id or item number and served
/// first-in-first-out; `viewer()` and `owners()` answer a fixed, settable result.
/// Unscripted fetches answer `.notModified`, unscripted activity probes answer
/// `false`. Every network call is recorded in `calls`
/// (`rateLimit()` is local state, not a call, and is not recorded); repos whose
/// conditional state was forgotten are recorded in `forgotten`.
actor StubGitHubAPI: GitHubAPI {
    enum Call: Equatable, Sendable {
        case viewer
        case owners
        case repositories(owner: String)
        case items(repo: RepoID, query: IssueQuery)
        case pullDetails(repo: RepoID)
        case activity(number: Int, since: Date, viewers: ViewerLogins)
        case renderedBody(number: Int, repo: RepoID)
        case insights(repo: RepoID, since: Date)
        case setAssigned(Bool, login: String, number: Int, repo: RepoID)
    }

    typealias Scripted<T: Sendable> = Result<Fetch<T>, GitHubError>

    private(set) var calls: [Call] = []
    private(set) var forgotten: [RepoID] = []
    private var repoLists: [String: [Scripted<[RepoListing]>]] = [:]
    private var itemResults: [RepoID: [Scripted<[Item]>]] = [:]
    private var pullResults: [RepoID: [Scripted<[Int: PullDetails]>]] = [:]
    private var activityResults: [Int: [Result<Bool, GitHubError>]] = [:]
    private var renderedBodies: [Int: [Result<String?, GitHubError>]] = [:]
    private var insightsResults: [RepoID: [Result<RepoInsights, GitHubError>]] = [:]
    private var assignResults: [Int: [Result<[String], any Error>]] = [:]
    private var timelines: [Int: [String]] = [:]
    private var currentRateLimit: RateLimit?
    private var cancellingProbes: Set<Int> = []
    private var viewerResult: Result<Viewer, GitHubError> = .success(Viewer(id: AccountID(rawValue: 42), login: "me"))
    private var ownersResult: Result<[OwnerRef], GitHubError> = .success([])
    private var heldItems: RepoID?
    private var heldContinuation: CheckedContinuation<Void, Never>?
    private var holdWaiters: [CheckedContinuation<Void, Never>] = []
    private var heldRepositories: String?
    private var heldRepositoriesContinuation: CheckedContinuation<Void, Never>?
    private var repositoriesWaiters: [CheckedContinuation<Void, Never>] = []
    private var heldAssign: Int?
    private var heldAssignContinuation: CheckedContinuation<Void, Never>?
    private var assignWaiters: [CheckedContinuation<Void, Never>] = []

    /// Repos listed with zero stats.
    func scriptRepositories(_ owner: String, _ results: Scripted<[RepoRef]>...) {
        repoLists[owner, default: []] += results.map { result in
            result.map { fetch in
                switch fetch {
                case .notModified: .notModified
                case .fresh(let refs): .fresh(refs.map { RepoListing(ref: $0, stats: RepoStats()) })
                }
            }
        }
    }

    func scriptListings(_ owner: String, _ results: Scripted<[RepoListing]>...) {
        repoLists[owner, default: []] += results
    }

    func scriptItems(_ repo: RepoRef, _ results: Scripted<[Item]>...) {
        itemResults[repo.id, default: []] += results
    }

    func scriptPullDetails(_ repo: RepoRef, _ results: Scripted<[Int: PullDetails]>...) {
        pullResults[repo.id, default: []] += results
    }

    func scriptActivity(_ number: Int, _ results: Result<Bool, GitHubError>...) {
        activityResults[number, default: []] += results
    }

    func scriptRenderedBody(_ number: Int, _ results: Result<String?, GitHubError>...) {
        renderedBodies[number, default: []] += results
    }

    func scriptInsights(_ repo: RepoRef, _ results: Result<RepoInsights, GitHubError>...) {
        insightsResults[repo.id, default: []] += results
    }

    func scriptAssigned(_ number: Int, _ results: Result<[String], any Error>...) {
        assignResults[number, default: []] += results
    }

    /// The probe for this item number answers from these timeline actors: true when any of them
    /// is not one of the viewers. Takes precedence over `scriptActivity`.
    func scriptTimeline(_ number: Int, actors: [String]) {
        timelines[number] = actors
    }

    /// The probe for this item number cancels the calling task, then fails like a cancelled
    /// request that surfaced as a plain network error.
    func cancelTaskOnActivity(_ number: Int) {
        cancellingProbes.insert(number)
    }

    /// Answer of every `viewer()` call from now on.
    func setViewer(_ result: Result<Viewer, GitHubError>) {
        viewerResult = result
    }

    /// Answer of every `owners()` call from now on.
    func setOwners(_ result: Result<[OwnerRef], GitHubError>) {
        ownersResult = result
    }

    /// The next `items` call for this repo suspends until `releaseItems()`.
    func holdItems(_ repo: RepoRef) {
        heldItems = repo.id
    }

    /// Returns once a held `items` call is suspended.
    func waitForHeldItems() async {
        guard heldContinuation == nil else { return }
        await withCheckedContinuation { holdWaiters.append($0) }
    }

    func releaseItems() {
        heldContinuation?.resume()
        heldContinuation = nil
    }

    /// The next `repositories` call for this owner login suspends until `releaseRepositories()`.
    func holdRepositories(_ owner: String) {
        heldRepositories = owner
    }

    /// Returns once a held `repositories` call is suspended.
    func waitForHeldRepositories() async {
        guard heldRepositoriesContinuation == nil else { return }
        await withCheckedContinuation { repositoriesWaiters.append($0) }
    }

    func releaseRepositories() {
        heldRepositoriesContinuation?.resume()
        heldRepositoriesContinuation = nil
    }

    /// The next `setAssigned` call for this item number suspends until `releaseAssign()`.
    func holdAssign(_ number: Int) {
        heldAssign = number
    }

    /// Returns once a held `setAssigned` call is suspended.
    func waitForHeldAssign() async {
        guard heldAssignContinuation == nil else { return }
        await withCheckedContinuation { assignWaiters.append($0) }
    }

    func releaseAssign() {
        heldAssignContinuation?.resume()
        heldAssignContinuation = nil
    }

    func setRateLimit(_ limit: RateLimit?) {
        currentRateLimit = limit
    }

    func resetCalls() {
        calls = []
    }

    // MARK: GitHubAPI

    func viewer() async throws -> Viewer {
        calls.append(.viewer)
        return try viewerResult.get()
    }

    func owners() async throws -> [OwnerRef] {
        calls.append(.owners)
        return try ownersResult.get()
    }

    func repositories(of owner: OwnerRef) async throws -> Fetch<[RepoListing]> {
        calls.append(.repositories(owner: owner.login))
        if heldRepositories == owner.login {
            heldRepositories = nil
            await withCheckedContinuation { continuation in
                heldRepositoriesContinuation = continuation
                repositoriesWaiters.forEach { $0.resume() }
                repositoriesWaiters = []
            }
        }
        return try (Self.pop(&repoLists, owner.login) ?? .success(.notModified)).get()
    }

    func items(in repo: RepoRef, query: IssueQuery) async throws -> Fetch<[Item]> {
        calls.append(.items(repo: repo.id, query: query))
        if heldItems == repo.id {
            heldItems = nil
            await withCheckedContinuation { continuation in
                heldContinuation = continuation
                holdWaiters.forEach { $0.resume() }
                holdWaiters = []
            }
        }
        return try (Self.pop(&itemResults, repo.id) ?? .success(.notModified)).get()
    }

    func openPullDetails(in repo: RepoRef) async throws -> Fetch<[Int: PullDetails]> {
        calls.append(.pullDetails(repo: repo.id))
        return try (Self.pop(&pullResults, repo.id) ?? .success(.notModified)).get()
    }

    func hasOtherActivity(on item: Item, in repo: RepoRef, since: Date, viewers: ViewerLogins) async throws -> Bool {
        calls.append(.activity(number: item.key.number, since: since, viewers: viewers))
        if cancellingProbes.contains(item.key.number) {
            withUnsafeCurrentTask { $0?.cancel() }
            throw GitHubError.network("cancelled")
        }
        if let actors = timelines[item.key.number] {
            return actors.contains { !viewers.contains($0) }
        }
        return try (Self.pop(&activityResults, item.key.number) ?? .success(false)).get()
    }

    func renderedBody(number: Int, in repo: RepoRef) async throws -> String? {
        calls.append(.renderedBody(number: number, repo: repo.id))
        return try (Self.pop(&renderedBodies, number) ?? .success(nil)).get()
    }

    func insights(for repo: RepoRef, since: Date) async throws -> RepoInsights {
        calls.append(.insights(repo: repo.id, since: since))
        return try (Self.pop(&insightsResults, repo.id) ?? .success(RepoInsights())).get()
    }

    func setAssigned(_ assigned: Bool, login: String, number: Int, in repo: RepoRef) async throws -> [String] {
        calls.append(.setAssigned(assigned, login: login, number: number, repo: repo.id))
        if heldAssign == number {
            heldAssign = nil
            await withCheckedContinuation { continuation in
                heldAssignContinuation = continuation
                assignWaiters.forEach { $0.resume() }
                assignWaiters = []
            }
        }
        return try (Self.pop(&assignResults, number) ?? .success(assigned ? [login] : [])).get()
    }

    func rateLimit() async -> RateLimit? {
        currentRateLimit
    }

    func forgetConditionalState(for repo: RepoRef) async {
        forgotten.append(repo.id)
    }

    private static func pop<Key: Hashable, Value>(_ queues: inout [Key: [Value]], _ key: Key) -> Value? {
        guard var queue = queues[key], !queue.isEmpty else { return nil }
        let next = queue.removeFirst()
        queues[key] = queue
        return next
    }
}
