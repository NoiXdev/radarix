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
