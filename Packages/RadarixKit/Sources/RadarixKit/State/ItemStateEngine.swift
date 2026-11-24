import Foundation

/// Pure rules deciding whether an item is new, updated or seen.
public enum ItemStateEngine {
    /// First sync of a repo: everything that exists is already seen.
    public static func baseline(_ items: [Item], at date: Date) -> [ItemRecord] {
        items.map {
            ItemRecord(item: $0, attention: .seen, seenAt: date, commentsAtSeen: $0.commentCount)
        }
    }

    /// True when a seen item moved since it was seen, so the caller must find out
    /// whether anyone other than the viewer caused it.
    public static func needsActivityCheck(previous: ItemRecord?, fetched: Item) -> Bool {
        guard let previous, previous.attention == .seen, let seenAt = previous.seenAt else { return false }
        return fetched.updatedAt > seenAt
    }

    public static func apply(
        fetched: Item, previous: ItemRecord?, viewers: ViewerLogins, otherActivity: Bool?
    ) -> ItemRecord {
        guard var record = previous else {
            if viewers.contains(fetched.author.login) {
                return ItemRecord(item: fetched, attention: .seen, seenAt: fetched.updatedAt, commentsAtSeen: fetched.commentCount)
            }
            return ItemRecord(item: fetched, attention: .new, seenAt: nil, commentsAtSeen: 0)
        }
        let moved = needsActivityCheck(previous: previous, fetched: fetched)
        record.item = fetched
        guard moved else { return record }
        if otherActivity == false {
            record.seenAt = fetched.updatedAt
            record.commentsAtSeen = fetched.commentCount
        } else {
            record.attention = .updated
        }
        return record
    }

    public static func markSeen(_ record: ItemRecord, at date: Date) -> ItemRecord {
        var r = record
        r.attention = .seen
        r.seenAt = date
        r.commentsAtSeen = r.item.commentCount
        return r
    }

    public static func markUnseen(_ record: ItemRecord) -> ItemRecord {
        var r = record
        r.attention = .updated
        return r
    }

    public static func isListed(_ record: ItemRecord) -> Bool {
        record.item.status == .open || record.attention != .seen
    }
}
