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

    public var newComments: Int { max(0, item.commentCount - commentsAtSeen) }
}
