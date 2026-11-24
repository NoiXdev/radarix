import Foundation

public struct Viewer: Sendable, Equatable {
    public let id: AccountID
    public let login: String
    public init(id: AccountID, login: String) {
        self.id = id
        self.login = login
    }
}

public struct PullDetails: Sendable, Equatable {
    public let isDraft: Bool
    public let requestedReviewers: [String]
    public init(isDraft: Bool, requestedReviewers: [String]) {
        self.isDraft = isDraft
        self.requestedReviewers = requestedReviewers
    }
}

public enum IssueQuery: Sendable, Equatable {
    case openForBaseline
    case changed(since: Date)
}

/// Everything the sync engine needs from GitHub.
public protocol GitHubAPI: Sendable {
    func viewer() async throws -> Viewer
    /// The viewer (user) first, then the organizations they belong to.
    func owners() async throws -> [OwnerRef]
    func repositories(of owner: OwnerRef) async throws -> Fetch<[RepoRef]>
    func items(in repo: RepoRef, query: IssueQuery) async throws -> Fetch<[Item]>
    func openPullDetails(in repo: RepoRef) async throws -> Fetch<[Int: PullDetails]>
    func hasOtherActivity(on item: Item, in repo: RepoRef, since: Date, viewer: String) async throws -> Bool
    func rateLimit() async -> RateLimit?
    /// Forget cached conditional-request state (ETags) for everything under this repo.
    func forgetConditionalState(for repo: RepoRef) async
}

extension GitHubClient: GitHubAPI {
    public func viewer() async throws -> Viewer {
        let user: UserDTO = try await get("/user", query: [])
        return Viewer(id: AccountID(rawValue: user.id), login: user.login)
    }

    public func owners() async throws -> [OwnerRef] {
        let me = try await viewer()
        let orgs: [OrgDTO] = try await getAllPages("/user/orgs", query: [])
        return [OwnerRef(login: me.login, kind: .user)] + orgs.map { OwnerRef(login: $0.login, kind: .organization) }
    }

    public func repositories(of owner: OwnerRef) async throws -> Fetch<[RepoRef]> {
        let fetched: Fetch<[RepoDTO]>
        switch owner.kind {
        case .user:
            fetched = try await getAllPagesConditional("/user/repos", query: [URLQueryItem(name: "affiliation", value: "owner")])
        case .organization:
            fetched = try await getAllPagesConditional("/orgs/\(owner.login)/repos", query: [URLQueryItem(name: "type", value: "all")])
        }
        switch fetched {
        case .notModified:
            return .notModified
        case .fresh(let repos):
            return .fresh(repos.map {
                RepoRef(id: RepoID(rawValue: $0.id), owner: $0.owner.login, name: $0.name,
                        isPrivate: $0.private, isArchived: $0.archived, isFork: $0.fork)
            })
        }
    }

    public func items(in repo: RepoRef, query: IssueQuery) async throws -> Fetch<[Item]> {
        var items: [URLQueryItem]
        switch query {
        case .openForBaseline:
            items = [URLQueryItem(name: "state", value: "open")]
        case .changed:
            items = [URLQueryItem(name: "state", value: "all")]
        }
        items += [URLQueryItem(name: "sort", value: "updated"), URLQueryItem(name: "direction", value: "desc")]
        if case .changed(let since) = query {
            // Fixed format: the URL (and so the ETag cache key) must be identical for the same Date.
            items.append(URLQueryItem(name: "since", value: ISO8601DateFormatter().string(from: since)))
        }
        let path = "/repos/\(repo.owner)/\(repo.name)/issues"
        let fetched: Fetch<[IssueDTO]>
        if case .openForBaseline = query {
            // A baseline must always see the full list, never a 304.
            fetched = .fresh(try await getAllPages(path, query: items))
        } else {
            fetched = try await getAllPagesConditional(path, query: items)
        }
        switch fetched {
        case .notModified: return .notModified
        case .fresh(let issues): return .fresh(issues.map { $0.toItem(repo: repo.id) })
        }
    }

    public func openPullDetails(in repo: RepoRef) async throws -> Fetch<[Int: PullDetails]> {
        let fetched: Fetch<[PullDTO]> = try await getAllPagesConditional(
            "/repos/\(repo.owner)/\(repo.name)/pulls", query: [URLQueryItem(name: "state", value: "open")])
        switch fetched {
        case .notModified:
            return .notModified
        case .fresh(let pulls):
            var details: [Int: PullDetails] = [:]
            for pull in pulls {
                details[pull.number] = PullDetails(isDraft: pull.draft ?? false,
                                                   requestedReviewers: (pull.requestedReviewers ?? []).map(\.login))
            }
            return .fresh(details)
        }
    }

    public func hasOtherActivity(on item: Item, in repo: RepoRef, since: Date, viewer: String) async throws -> Bool {
        let entries: [TimelineEntryDTO] = try await getLastPage(
            "/repos/\(repo.owner)/\(repo.name)/issues/\(item.key.number)/timeline", query: [])
        return ActivityProbe.hasOtherActivity(
            in: entries, since: since, viewer: viewer,
            itemAuthorIsViewer: item.author.login.caseInsensitiveCompare(viewer) == .orderedSame)
    }

    public func rateLimit() async -> RateLimit? { latestRateLimit }
}
