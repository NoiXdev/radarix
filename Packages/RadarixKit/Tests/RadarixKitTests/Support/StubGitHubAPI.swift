import Foundation
@testable import RadarixKit

/// Scriptable `GitHubAPI` for sync tests.
///
/// Results are queued per owner login, repo id or item number and served
/// first-in-first-out. Unscripted fetches answer `.notModified`, unscripted
/// activity probes answer `false`. Every network call is recorded in `calls`
/// (`rateLimit()` is local state, not a call, and is not recorded).
actor StubGitHubAPI: GitHubAPI {
    enum Call: Equatable, Sendable {
        case viewer
        case owners
        case repositories(owner: String)
        case items(repo: RepoID, query: IssueQuery)
        case pullDetails(repo: RepoID)
        case activity(number: Int, since: Date, viewer: String)
    }

    typealias Scripted<T: Sendable> = Result<Fetch<T>, GitHubError>

    private(set) var calls: [Call] = []
    private var repoLists: [String: [Scripted<[RepoRef]>]] = [:]
    private var itemResults: [RepoID: [Scripted<[Item]>]] = [:]
    private var pullResults: [RepoID: [Scripted<[Int: PullDetails]>]] = [:]
    private var activityResults: [Int: [Result<Bool, GitHubError>]] = [:]
    private var currentRateLimit: RateLimit?

    func scriptRepositories(_ owner: String, _ results: Scripted<[RepoRef]>...) {
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

    func setRateLimit(_ limit: RateLimit?) {
        currentRateLimit = limit
    }

    func resetCalls() {
        calls = []
    }

    // MARK: GitHubAPI

    func viewer() async throws -> Viewer {
        calls.append(.viewer)
        return Viewer(id: AccountID(rawValue: 42), login: "me")
    }

    func owners() async throws -> [OwnerRef] {
        calls.append(.owners)
        return []
    }

    func repositories(of owner: OwnerRef) async throws -> Fetch<[RepoRef]> {
        calls.append(.repositories(owner: owner.login))
        return try (Self.pop(&repoLists, owner.login) ?? .success(.notModified)).get()
    }

    func items(in repo: RepoRef, query: IssueQuery) async throws -> Fetch<[Item]> {
        calls.append(.items(repo: repo.id, query: query))
        return try (Self.pop(&itemResults, repo.id) ?? .success(.notModified)).get()
    }

    func openPullDetails(in repo: RepoRef) async throws -> Fetch<[Int: PullDetails]> {
        calls.append(.pullDetails(repo: repo.id))
        return try (Self.pop(&pullResults, repo.id) ?? .success(.notModified)).get()
    }

    func hasOtherActivity(on item: Item, in repo: RepoRef, since: Date, viewer: String) async throws -> Bool {
        calls.append(.activity(number: item.key.number, since: since, viewer: viewer))
        return try (Self.pop(&activityResults, item.key.number) ?? .success(false)).get()
    }

    func rateLimit() async -> RateLimit? {
        currentRateLimit
    }

    private static func pop<Key: Hashable, Value>(_ queues: inout [Key: [Value]], _ key: Key) -> Value? {
        guard var queue = queues[key], !queue.isEmpty else { return nil }
        let next = queue.removeFirst()
        queues[key] = queue
        return next
    }
}
