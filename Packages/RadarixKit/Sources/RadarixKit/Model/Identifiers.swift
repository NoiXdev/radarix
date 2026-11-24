public struct AccountID: Sendable, Codable, Hashable {
    public let rawValue: Int64
    public init(rawValue: Int64) { self.rawValue = rawValue }
}

public struct RepoID: Sendable, Codable, Hashable {
    public let rawValue: Int64
    public init(rawValue: Int64) { self.rawValue = rawValue }
}

/// Stable identity of an issue or pull request: numeric repo id plus issue number.
public struct ItemKey: Sendable, Codable, Hashable {
    public let repo: RepoID
    public let number: Int
    public init(repo: RepoID, number: Int) {
        self.repo = repo
        self.number = number
    }
}
