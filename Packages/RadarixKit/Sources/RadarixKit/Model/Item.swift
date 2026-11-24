import Foundation

public enum ItemKind: String, Sendable, Codable, Hashable {
    case issue, pullRequest
}

public enum ItemStatus: String, Sendable, Codable, Hashable {
    case open, closed, merged
}

public struct Actor: Sendable, Codable, Hashable {
    public let login: String
    public let isBot: Bool

    private static let botSuffix = "[bot]"
    private static let knownBots = [
        "dependabot": "Dependabot",
        "renovate": "Renovate",
        "github-actions": "GitHub Actions",
    ]

    public init(login: String, apiType: String) {
        self.login = login
        self.isBot = apiType == "Bot" || login.hasSuffix(Self.botSuffix)
    }

    public var botDisplayName: String? {
        guard isBot else { return nil }
        let base = login.hasSuffix(Self.botSuffix) ? String(login.dropLast(Self.botSuffix.count)) : login
        return Self.knownBots[base] ?? base
    }
}

public struct Label: Sendable, Codable, Hashable {
    public let name: String
    /// Hex without `#`; nil when GitHub sends none.
    public let colorHex: String?
    public init(name: String, colorHex: String?) {
        self.name = name
        self.colorHex = colorHex
    }
}

public struct Item: Sendable, Codable, Hashable, Identifiable {
    public let key: ItemKey
    public let kind: ItemKind
    public var title: String
    public var url: URL
    public var author: Actor
    public var status: ItemStatus
    public var isDraft: Bool
    public var labels: [Label]
    public var assignees: [String]
    public var requestedReviewers: [String]
    public var commentCount: Int
    public var createdAt: Date
    public var updatedAt: Date
    public var bodyExcerpt: String

    public var id: ItemKey { key }

    public init(
        key: ItemKey, kind: ItemKind, title: String, url: URL, author: Actor, status: ItemStatus,
        isDraft: Bool, labels: [Label], assignees: [String], requestedReviewers: [String],
        commentCount: Int, createdAt: Date, updatedAt: Date, bodyExcerpt: String
    ) {
        self.key = key
        self.kind = kind
        self.title = title
        self.url = url
        self.author = author
        self.status = status
        self.isDraft = isDraft
        self.labels = labels
        self.assignees = assignees
        self.requestedReviewers = requestedReviewers
        self.commentCount = commentCount
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.bodyExcerpt = bodyExcerpt
    }

    private enum CodingKeys: String, CodingKey {
        case key, kind, title, url, author, status, isDraft, labels, assignees, requestedReviewers
        case commentCount, createdAt, updatedAt, bodyExcerpt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = try c.decode(ItemKey.self, forKey: .key)
        kind = try c.decode(ItemKind.self, forKey: .kind)
        title = try c.decode(String.self, forKey: .title)
        url = try c.decode(URL.self, forKey: .url)
        author = try c.decode(Actor.self, forKey: .author)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        status = try c.decodeIfPresent(ItemStatus.self, forKey: .status) ?? .open
        isDraft = try c.decodeIfPresent(Bool.self, forKey: .isDraft) ?? false
        labels = try c.decodeIfPresent([Label].self, forKey: .labels) ?? []
        assignees = try c.decodeIfPresent([String].self, forKey: .assignees) ?? []
        requestedReviewers = try c.decodeIfPresent([String].self, forKey: .requestedReviewers) ?? []
        commentCount = try c.decodeIfPresent(Int.self, forKey: .commentCount) ?? 0
        bodyExcerpt = try c.decodeIfPresent(String.self, forKey: .bodyExcerpt) ?? ""
    }
}
