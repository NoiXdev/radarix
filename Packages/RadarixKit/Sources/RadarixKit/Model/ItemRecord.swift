import Foundation

public enum Attention: String, Sendable, Codable, Hashable {
    case new, updated, seen
}

public struct ItemRecord: Sendable, Codable, Hashable {
    public var item: Item
    public var attention: Attention
    public var seenAt: Date?
    public var commentsAtSeen: Int

    public init(item: Item, attention: Attention, seenAt: Date?, commentsAtSeen: Int) {
        self.item = item
        self.attention = attention
        self.seenAt = seenAt
        self.commentsAtSeen = commentsAtSeen
    }

    private enum CodingKeys: String, CodingKey { case item, attention, seenAt, commentsAtSeen }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        item = try c.decode(Item.self, forKey: .item)
        attention = try c.decode(Attention.self, forKey: .attention)
        seenAt = try c.decodeIfPresent(Date.self, forKey: .seenAt)
        commentsAtSeen = try c.decodeIfPresent(Int.self, forKey: .commentsAtSeen) ?? 0
    }

    public var newComments: Int { max(0, item.commentCount - commentsAtSeen) }
}
