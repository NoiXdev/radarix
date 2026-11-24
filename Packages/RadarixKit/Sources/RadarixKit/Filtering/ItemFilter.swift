import Foundation

/// The list filters. Flags in one group are ORed; groups are ANDed.
public struct FilterSet: Codable, Sendable, Equatable {
    /// Attention. Both false = any attention, including seen items that are still listed.
    public var new = true, updated = true
    /// Assignment. All false = no constraint.
    public var unassigned = false, assignedToMe = false, reviewRequested = false
    /// Kind. Both false = both kinds.
    public var pullRequests = false, issues = false

    public init() {}
}

public enum BotScope: Sendable { case humans, bots, all }

public struct AttentionCounts: Sendable, Equatable {
    public var new = 0, updated = 0
    public var total: Int { new + updated }
}

public enum ItemFilter {
    /// Listed records matching the filter and bot scope, newest `updatedAt` first.
    public static func visible(_ records: [ItemRecord], filter: FilterSet, viewer: String, scope: BotScope) -> [ItemRecord] {
        records
            .filter { ItemStateEngine.isListed($0) && matches($0, filter, viewer: viewer) && inScope($0, scope) }
            .sorted { a, b in
                if a.item.updatedAt != b.item.updatedAt { return a.item.updatedAt > b.item.updatedAt }
                if a.item.key.repo != b.item.key.repo { return a.item.key.repo.rawValue < b.item.key.repo.rawValue }
                return a.item.key.number < b.item.key.number
            }
    }

    /// `.badge` shows bots in the main list; `.grouped` and `.hidden` keep them out of it.
    public static func scope(for mode: BotDisplayMode) -> BotScope {
        switch mode {
        case .badge: .all
        case .grouped, .hidden: .humans
        }
    }

    /// New and updated listed records. Bots are left out only in `.hidden` mode.
    public static func counts(_ records: [ItemRecord], bots: BotDisplayMode) -> AttentionCounts {
        var counts = AttentionCounts()
        for record in records where ItemStateEngine.isListed(record) {
            if bots == .hidden, record.item.author.isBot { continue }
            switch record.attention {
            case .new: counts.new += 1
            case .updated: counts.updated += 1
            case .seen: break
            }
        }
        return counts
    }

    private static func matches(_ record: ItemRecord, _ filter: FilterSet, viewer: String) -> Bool {
        let item = record.item
        let attention = (!filter.new && !filter.updated)
            || (filter.new && record.attention == .new)
            || (filter.updated && record.attention == .updated)

        let isViewer = { (login: String) in login.caseInsensitiveCompare(viewer) == .orderedSame }
        let anyAssignment = filter.unassigned || filter.assignedToMe || filter.reviewRequested
        let assignment = !anyAssignment
            || (filter.unassigned && item.assignees.isEmpty)
            || (filter.assignedToMe && item.assignees.contains(where: isViewer))
            || (filter.reviewRequested && item.requestedReviewers.contains(where: isViewer))

        let kind = (!filter.pullRequests && !filter.issues)
            || (filter.pullRequests && item.kind == .pullRequest)
            || (filter.issues && item.kind == .issue)

        return attention && assignment && kind
    }

    private static func inScope(_ record: ItemRecord, _ scope: BotScope) -> Bool {
        switch scope {
        case .humans: !record.item.author.isBot
        case .bots: record.item.author.isBot
        case .all: true
        }
    }
}
