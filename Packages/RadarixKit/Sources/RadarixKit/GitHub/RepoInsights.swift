import Foundation

/// A count over a period. `atLeast` marks a count that stopped at the paging cap.
public struct PeriodCount: Sendable, Equatable {
    public var value: Int
    public var atLeast: Bool

    public init(value: Int, atLeast: Bool) {
        self.value = value
        self.atLeast = atLeast
    }
}

public enum PeriodMetric: String, Sendable, CaseIterable {
    case stars, forks, openedIssues, openedPulls, mergedPulls
}

public struct Release: Sendable, Equatable {
    public var name: String?
    public var tag: String
    public var publishedAt: Date?

    public init(name: String?, tag: String, publishedAt: Date?) {
        self.name = name
        self.tag = tag
        self.publishedAt = publishedAt
    }
}

public struct RepoInsights: Sendable, Equatable {
    public var description: String?
    public var language: String?
    public var license: String?
    public var topics: [String]
    public var stars: Int
    public var forks: Int
    public var watchers: Int
    public var openIssues: Int
    public var openPulls: Int
    public var latestRelease: Release?
    public var period: [PeriodMetric: PeriodCount]

    public init(
        description: String? = nil, language: String? = nil, license: String? = nil, topics: [String] = [],
        stars: Int = 0, forks: Int = 0, watchers: Int = 0, openIssues: Int = 0, openPulls: Int = 0,
        latestRelease: Release? = nil, period: [PeriodMetric: PeriodCount] = [:]
    ) {
        self.description = description
        self.language = language
        self.license = license
        self.topics = topics
        self.stars = stars
        self.forks = forks
        self.watchers = watchers
        self.openIssues = openIssues
        self.openPulls = openPulls
        self.latestRelease = latestRelease
        self.period = period
    }
}

extension RepoInsights {
    static let query = """
    query($owner: String!, $name: String!, $issues: String!, $pulls: String!, $merged: String!) {
      repository(owner: $owner, name: $name) {
        description
        primaryLanguage { name }
        licenseInfo { spdxId name }
        repositoryTopics(first: 20) { nodes { topic { name } } }
        stargazerCount
        forkCount
        watchers { totalCount }
        issues(states: OPEN) { totalCount }
        pullRequests(states: OPEN) { totalCount }
        latestRelease { name tagName publishedAt }
        stargazers(first: 100, orderBy: {field: STARRED_AT, direction: DESC}) { pageInfo { hasNextPage endCursor } edges { starredAt } }
        forks(first: 100, orderBy: {field: CREATED_AT, direction: DESC}) { pageInfo { hasNextPage endCursor } nodes { createdAt } }
      }
      openedIssues: search(query: $issues, type: ISSUE, first: 1) { issueCount }
      openedPulls: search(query: $pulls, type: ISSUE, first: 1) { issueCount }
      mergedPulls: search(query: $merged, type: ISSUE, first: 1) { issueCount }
    }
    """

    static let starsPageQuery = """
    query($owner: String!, $name: String!, $after: String!) {
      repository(owner: $owner, name: $name) {
        stargazers(first: 100, after: $after, orderBy: {field: STARRED_AT, direction: DESC}) { pageInfo { hasNextPage endCursor } edges { starredAt } }
      }
    }
    """

    static let forksPageQuery = """
    query($owner: String!, $name: String!, $after: String!) {
      repository(owner: $owner, name: $name) {
        forks(first: 100, after: $after, orderBy: {field: CREATED_AT, direction: DESC}) { pageInfo { hasNextPage endCursor } nodes { createdAt } }
      }
    }
    """

    /// Pages read at most per metric, 100 entries each.
    static let maxPages = 5
}

// MARK: Response DTOs

private struct PageInfo: Decodable {
    let hasNextPage: Bool
    let endCursor: String?
}

private struct StargazerPage: Decodable {
    struct Edge: Decodable { let starredAt: Date }
    let pageInfo: PageInfo
    let edges: [Edge]
}

private struct ForkPage: Decodable {
    struct Node: Decodable { let createdAt: Date }
    let pageInfo: PageInfo
    let nodes: [Node]
}

private struct SearchCount: Decodable {
    let issueCount: Int
}

private struct TotalCount: Decodable {
    let totalCount: Int
}

private struct InsightsResponse: Decodable {
    struct Repository: Decodable {
        struct Language: Decodable { let name: String }
        struct License: Decodable { let spdxId: String?; let name: String? }
        struct Topics: Decodable {
            struct Node: Decodable {
                struct Topic: Decodable { let name: String }
                let topic: Topic
            }
            let nodes: [Node]
        }
        struct LatestRelease: Decodable {
            let name: String?
            let tagName: String
            let publishedAt: Date?
        }

        let description: String?
        let primaryLanguage: Language?
        let licenseInfo: License?
        let repositoryTopics: Topics
        let stargazerCount: Int
        let forkCount: Int
        let watchers: TotalCount
        let issues: TotalCount
        let pullRequests: TotalCount
        let latestRelease: LatestRelease?
        let stargazers: StargazerPage
        let forks: ForkPage
    }

    let repository: Repository
    let openedIssues: SearchCount
    let openedPulls: SearchCount
    let mergedPulls: SearchCount
}

private struct StarsFollowUp: Decodable {
    struct Repository: Decodable { let stargazers: StargazerPage }
    let repository: Repository
}

private struct ForksFollowUp: Decodable {
    struct Repository: Decodable { let forks: ForkPage }
    let repository: Repository
}

// MARK: Loading

private struct DatePage {
    let dates: [Date]
    let hasNextPage: Bool
    let endCursor: String?
}

extension GitHubClient {
    public func insights(for repo: RepoRef, since: Date) async throws -> RepoInsights {
        let day = Self.searchDay(since)
        let scope = "repo:\(repo.owner)/\(repo.name)"
        let response: InsightsResponse = try await graphQL(RepoInsights.query, variables: [
            "owner": repo.owner, "name": repo.name,
            "issues": "\(scope) is:issue created:>=\(day)",
            "pulls": "\(scope) is:pr created:>=\(day)",
            "merged": "\(scope) is:pr is:merged merged:>=\(day)",
        ])
        let source = response.repository

        let stars = try await countSince(since, first: Self.datePage(source.stargazers)) { cursor in
            let next: StarsFollowUp = try await self.graphQL(
                RepoInsights.starsPageQuery, variables: ["owner": repo.owner, "name": repo.name, "after": cursor])
            return Self.datePage(next.repository.stargazers)
        }
        let forks = try await countSince(since, first: Self.datePage(source.forks)) { cursor in
            let next: ForksFollowUp = try await self.graphQL(
                RepoInsights.forksPageQuery, variables: ["owner": repo.owner, "name": repo.name, "after": cursor])
            return Self.datePage(next.repository.forks)
        }

        let license = source.licenseInfo.flatMap { info -> String? in
            if let spdx = info.spdxId, spdx != "NOASSERTION" { return spdx }
            return info.name
        }
        return RepoInsights(
            description: source.description,
            language: source.primaryLanguage?.name,
            license: license,
            topics: source.repositoryTopics.nodes.map(\.topic.name),
            stars: source.stargazerCount,
            forks: source.forkCount,
            watchers: source.watchers.totalCount,
            openIssues: source.issues.totalCount,
            openPulls: source.pullRequests.totalCount,
            latestRelease: source.latestRelease.map { Release(name: $0.name, tag: $0.tagName, publishedAt: $0.publishedAt) },
            period: [
                .stars: stars,
                .forks: forks,
                .openedIssues: PeriodCount(value: response.openedIssues.issueCount, atLeast: false),
                .openedPulls: PeriodCount(value: response.openedPulls.issueCount, atLeast: false),
                .mergedPulls: PeriodCount(value: response.mergedPulls.issueCount, atLeast: false),
            ])
    }

    /// Counts entries dated `since` or later in a newest-first paged list. Reads the next page only
    /// while the whole current page is inside the period, up to `RepoInsights.maxPages` pages.
    private func countSince(
        _ since: Date, first: DatePage, next: (String) async throws -> DatePage
    ) async throws -> PeriodCount {
        var page = first
        var pagesRead = 1
        var value = 0
        while true {
            value += page.dates.filter { $0 >= since }.count
            guard page.hasNextPage, let cursor = page.endCursor, page.dates.allSatisfy({ $0 >= since }) else {
                return PeriodCount(value: value, atLeast: false)
            }
            if pagesRead >= RepoInsights.maxPages { return PeriodCount(value: value, atLeast: true) }
            page = try await next(cursor)
            pagesRead += 1
        }
    }

    private static func datePage(_ page: StargazerPage) -> DatePage {
        DatePage(dates: page.edges.map(\.starredAt), hasNextPage: page.pageInfo.hasNextPage, endCursor: page.pageInfo.endCursor)
    }

    private static func datePage(_ page: ForkPage) -> DatePage {
        DatePage(dates: page.nodes.map(\.createdAt), hasNextPage: page.pageInfo.hasNextPage, endCursor: page.pageInfo.endCursor)
    }

    /// `yyyy-MM-dd` in UTC, for search qualifiers.
    private static func searchDay(_ date: Date) -> String {
        date.formatted(Date.ISO8601FormatStyle(timeZone: .gmt).year().month().day())
    }
}
