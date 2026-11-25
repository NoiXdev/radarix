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

/// Why assigning or unassigning the viewer did not happen.
public enum AssignError: Error, Equatable, Sendable {
    /// GitHub refused (403, 404) or silently left the assignee out: the sign-in lacks write access.
    case notPermitted
    /// No signed-in account owns the item's repo.
    case noOwner
}

/// Everything the sync engine needs from GitHub.
public protocol GitHubAPI: Sendable {
    func viewer() async throws -> Viewer
    /// The viewer (user) first, then the organizations they belong to.
    func owners() async throws -> [OwnerRef]
    func repositories(of owner: OwnerRef) async throws -> Fetch<[RepoListing]>
    func items(in repo: RepoRef, query: IssueQuery) async throws -> Fetch<[Item]>
    func openPullDetails(in repo: RepoRef) async throws -> Fetch<[Int: PullDetails]>
    func hasOtherActivity(on item: Item, in repo: RepoRef, since: Date, viewers: ViewerLogins) async throws -> Bool
    /// The item's description rendered to HTML by GitHub; nil when it has none. Never conditional.
    func renderedBody(number: Int, in repo: RepoRef) async throws -> String?
    /// Assigns (`true`) or unassigns (`false`) `login` on the item and returns the resulting assignee
    /// logins. Throws `AssignError.notPermitted` when GitHub refuses or does not reflect the request.
    func setAssigned(_ assigned: Bool, login: String, number: Int, in repo: RepoRef) async throws -> [String]
    func rateLimit() async -> RateLimit?
    /// Forget cached conditional-request state (ETags) for everything under this repo.
    func forgetConditionalState(for repo: RepoRef) async
}

extension GitHubClient: GitHubAPI {
    /// Only page 1 of a paged list is conditional (its ETag stands for the whole list), so every
    /// list is sorted by update time: any change moves the changed entry onto page 1.
    private static let newestFirst = [URLQueryItem(name: "sort", value: "updated"), URLQueryItem(name: "direction", value: "desc")]

    public func viewer() async throws -> Viewer {
        let user: UserDTO = try await get("/user", query: [])
        return Viewer(id: AccountID(rawValue: user.id), login: user.login)
    }

    public func owners() async throws -> [OwnerRef] {
        let me = try await viewer()
        let orgs: [OrgDTO] = try await getAllPages("/user/orgs", query: [])
        return [OwnerRef(login: me.login, kind: .user)] + orgs.map { OwnerRef(login: $0.login, kind: .organization) }
    }

    public func repositories(of owner: OwnerRef) async throws -> Fetch<[RepoListing]> {
        let fetched: Fetch<[RepoDTO]>
        switch owner.kind {
        case .user:
            fetched = try await getAllPagesConditional(
                "/user/repos", query: [URLQueryItem(name: "affiliation", value: "owner")] + Self.newestFirst)
        case .organization:
            fetched = try await getAllPagesConditional(
                "/orgs/\(owner.login)/repos", query: [URLQueryItem(name: "type", value: "all")] + Self.newestFirst)
        }
        switch fetched {
        case .notModified:
            return .notModified
        case .fresh(let repos):
            return .fresh(repos.map {
                RepoListing(
                    ref: RepoRef(id: RepoID(rawValue: $0.id), owner: $0.owner.login, name: $0.name,
                                 isPrivate: $0.private, isArchived: $0.archived, isFork: $0.fork),
                    stats: RepoStats(
                        stars: $0.stargazersCount ?? 0, forks: $0.forksCount ?? 0,
                        openIssuesAndPulls: $0.openIssuesCount ?? 0,
                        pushedAt: $0.pushedAt, description: $0.description, language: $0.language))
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
        items += Self.newestFirst
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
            "/repos/\(repo.owner)/\(repo.name)/pulls", query: [URLQueryItem(name: "state", value: "open")] + Self.newestFirst)
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

    public func hasOtherActivity(on item: Item, in repo: RepoRef, since: Date, viewers: ViewerLogins) async throws -> Bool {
        let entries: [TimelineEntryDTO] = try await getLastPage(
            "/repos/\(repo.owner)/\(repo.name)/issues/\(item.key.number)/timeline", query: [])
        return ActivityProbe.hasOtherActivity(
            in: entries, since: since, viewers: viewers,
            itemAuthorIsViewer: viewers.contains(item.author.login))
    }

    public func renderedBody(number: Int, in repo: RepoRef) async throws -> String? {
        struct Rendered: Decodable { let bodyHtml: String? }
        let rendered: Rendered = try await get(
            "/repos/\(repo.owner)/\(repo.name)/issues/\(number)", query: [],
            accept: "application/vnd.github.html+json")
        guard let html = rendered.bodyHtml, !html.isEmpty else { return nil }
        return html
    }

    public func setAssigned(_ assigned: Bool, login: String, number: Int, in repo: RepoRef) async throws -> [String] {
        struct Body: Encodable { let assignees: [String] }
        struct Answer: Decodable {
            struct Assignee: Decodable { let login: String }
            let assignees: [Assignee]?
        }
        let body = try JSONEncoder().encode(Body(assignees: [login]))
        let answer: Answer
        do {
            answer = try await send(
                assigned ? "POST" : "DELETE", "/repos/\(repo.owner)/\(repo.name)/issues/\(number)/assignees", json: body)
        } catch GitHubError.forbidden, GitHubError.notFound {
            throw AssignError.notPermitted
        }
        let logins = (answer.assignees ?? []).map(\.login)
        let contains = logins.contains { $0.caseInsensitiveCompare(login) == .orderedSame }
        guard contains == assigned else { throw AssignError.notPermitted }
        return logins
    }

    public func rateLimit() async -> RateLimit? { latestRateLimit }
}
