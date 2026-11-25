import Foundation

public enum OwnerKind: String, Sendable, Codable, Hashable {
    case user, organization
}

public struct OwnerRef: Sendable, Codable, Hashable {
    public let login: String
    public let kind: OwnerKind
    public init(login: String, kind: OwnerKind) {
        self.login = login
        self.kind = kind
    }
}

/// Numbers and texts the repository listing carries along. Not part of `RepoRef`, which is
/// compared and hashed across sync.
public struct RepoStats: Sendable, Codable, Hashable {
    public var stars: Int
    public var forks: Int
    /// GitHub counts issues and pull requests together here.
    public var openIssuesAndPulls: Int
    public var pushedAt: Date?
    public var description: String?
    public var language: String?

    public init(
        stars: Int = 0, forks: Int = 0, openIssuesAndPulls: Int = 0,
        pushedAt: Date? = nil, description: String? = nil, language: String? = nil
    ) {
        self.stars = stars
        self.forks = forks
        self.openIssuesAndPulls = openIssuesAndPulls
        self.pushedAt = pushedAt
        self.description = description
        self.language = language
    }
}

/// One entry of a repository listing.
public struct RepoListing: Sendable, Equatable {
    public let ref: RepoRef
    public let stats: RepoStats

    public init(ref: RepoRef, stats: RepoStats) {
        self.ref = ref
        self.stats = stats
    }
}

public struct RepoRef: Sendable, Codable, Hashable {
    public let id: RepoID
    public let owner: String
    public let name: String
    public let isPrivate: Bool
    public let isArchived: Bool
    public let isFork: Bool

    public init(id: RepoID, owner: String, name: String, isPrivate: Bool, isArchived: Bool, isFork: Bool) {
        self.id = id
        self.owner = owner
        self.name = name
        self.isPrivate = isPrivate
        self.isArchived = isArchived
        self.isFork = isFork
    }

    public var fullName: String { "\(owner)/\(name)" }
}
