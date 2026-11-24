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

    private enum CodingKeys: String, CodingKey {
        case new, updated, unassigned, assignedToMe, reviewRequested, pullRequests, issues
    }

    /// Tolerant: a missing key keeps its default, so older or partial files still load.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = FilterSet()
        new = try c.decodeIfPresent(Bool.self, forKey: .new) ?? defaults.new
        updated = try c.decodeIfPresent(Bool.self, forKey: .updated) ?? defaults.updated
        unassigned = try c.decodeIfPresent(Bool.self, forKey: .unassigned) ?? defaults.unassigned
        assignedToMe = try c.decodeIfPresent(Bool.self, forKey: .assignedToMe) ?? defaults.assignedToMe
        reviewRequested = try c.decodeIfPresent(Bool.self, forKey: .reviewRequested) ?? defaults.reviewRequested
        pullRequests = try c.decodeIfPresent(Bool.self, forKey: .pullRequests) ?? defaults.pullRequests
        issues = try c.decodeIfPresent(Bool.self, forKey: .issues) ?? defaults.issues
    }

    /// The one filter predicate: groups are ANDed, flags inside a group ORed. Callers derive the facts from their own data.
    public func matches(
        attention: Attention, kind: ItemKind, isUnassigned: Bool, isAssignedToViewer: Bool, isReviewRequestedFromViewer: Bool
    ) -> Bool {
        let attentionMatch = (!new && !updated)
            || (new && attention == .new)
            || (updated && attention == .updated)

        let anyAssignment = unassigned || assignedToMe || reviewRequested
        let assignmentMatch = !anyAssignment
            || (unassigned && isUnassigned)
            || (assignedToMe && isAssignedToViewer)
            || (reviewRequested && isReviewRequestedFromViewer)

        let kindMatch = (!pullRequests && !issues)
            || (pullRequests && kind == .pullRequest)
            || (issues && kind == .issue)

        return attentionMatch && assignmentMatch && kindMatch
    }
}

public enum BotScope: Sendable { case humans, bots, all }

public struct AttentionCounts: Sendable, Equatable {
    public var new = 0, updated = 0
    public init(new: Int = 0, updated: Int = 0) {
        self.new = new
        self.updated = updated
    }
    public var total: Int { new + updated }
}

public enum ItemFilter {
    /// Listed records matching the filter and bot scope, newest `updatedAt` first.
    public static func visible(_ records: [ItemRecord], filter: FilterSet, viewers: ViewerLogins, scope: BotScope) -> [ItemRecord] {
        records
            .filter { ItemStateEngine.isListed($0) && matches($0, filter, viewers: viewers) && inScope($0, scope) }
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

    private static func matches(_ record: ItemRecord, _ filter: FilterSet, viewers: ViewerLogins) -> Bool {
        let item = record.item
        let isViewer = { (login: String) in viewers.contains(login) }
        return filter.matches(
            attention: record.attention, kind: item.kind, isUnassigned: item.assignees.isEmpty,
            isAssignedToViewer: item.assignees.contains(where: isViewer),
            isReviewRequestedFromViewer: item.requestedReviewers.contains(where: isViewer))
    }

    private static func inScope(_ record: ItemRecord, _ scope: BotScope) -> Bool {
        switch scope {
        case .humans: !record.item.author.isBot
        case .bots: record.item.author.isBot
        case .all: true
        }
    }
}
