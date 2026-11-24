import Foundation
import Testing
@testable import RadarixKit

private func record(
    _ number: Int, _ attention: Attention, repo: Int64 = 1, kind: ItemKind = .issue, status: ItemStatus = .open,
    author: String = "alice", bot: Bool = false, assignees: [String] = [], reviewers: [String] = [],
    updatedAt: Date = t0
) -> ItemRecord {
    var item = Item.fixture(
        repo: repo, number: number, kind: kind, author: author, status: status,
        assignees: assignees, requestedReviewers: reviewers, updatedAt: updatedAt)
    if bot { item.author = Actor(login: "\(author)[bot]", apiType: "Bot") }
    return ItemRecord(item: item, attention: attention, seenAt: attention == .seen ? updatedAt : nil, commentsAtSeen: 0)
}

private func numbers(_ records: [ItemRecord]) -> [Int] { records.map(\.item.key.number) }

private func visible(_ records: [ItemRecord], _ change: (inout FilterSet) -> Void = { _ in }, scope: BotScope = .all) -> [Int] {
    var filter = FilterSet()
    change(&filter)
    return numbers(ItemFilter.visible(records, filter: filter, viewers: ViewerLogins(["me"]), scope: scope))
}

struct ItemFilterTests {
    @Test func sharedPredicateMatchesItemFilter() {
        let records = [
            record(1, .new), record(2, .updated, kind: .pullRequest), record(3, .seen),
            record(4, .new, assignees: ["me"]), record(5, .updated, kind: .pullRequest, reviewers: ["me"]),
            record(6, .new, kind: .pullRequest, assignees: ["other"]), record(7, .seen, assignees: ["me"]),
        ]
        let viewers = ViewerLogins(["me"])
        var filters: [FilterSet] = [FilterSet()]
        for keyPath in [\FilterSet.new, \.updated, \.unassigned, \.assignedToMe, \.reviewRequested, \.pullRequests, \.issues] {
            var f = FilterSet()
            f[keyPath: keyPath].toggle()
            filters.append(f)
        }
        var combined = FilterSet()
        combined.assignedToMe = true
        combined.reviewRequested = true
        combined.pullRequests = true
        filters.append(combined)
        for filter in filters {
            let viaFilter = Set(numbers(ItemFilter.visible(records, filter: filter, viewers: viewers, scope: .all)))
            let direct = Set(records.filter { r in
                ItemStateEngine.isListed(r) && filter.matches(
                    attention: r.attention, kind: r.item.kind, isUnassigned: r.item.assignees.isEmpty,
                    isAssignedToViewer: r.item.assignees.contains(where: viewers.contains),
                    isReviewRequestedFromViewer: r.item.requestedReviewers.contains(where: viewers.contains))
            }.map(\.item.key.number))
            #expect(viaFilter == direct)
        }
    }

    @Test func defaultFilterShowsNewAndUpdatedHidesSeen() {
        let records = [record(1, .new), record(2, .updated), record(3, .seen)]
        #expect(Set(visible(records)) == [1, 2])
        #expect(visible(records) { $0.updated = false } == [1])
        #expect(visible(records) { $0.new = false } == [2])
        // Both off: any attention, including seen items that are still listed.
        #expect(Set(visible(records) { $0.new = false; $0.updated = false }) == [1, 2, 3])
    }

    @Test func assignmentFlagsAreOredWithinTheGroup() {
        let records = [
            record(1, .new),
            record(2, .new, assignees: ["ME"]),
            record(3, .new, assignees: ["bob"]),
            record(4, .new, assignees: ["bob"], reviewers: ["Me"]),
        ]
        #expect(Set(visible(records)) == [1, 2, 3, 4])
        #expect(visible(records) { $0.unassigned = true } == [1])
        #expect(visible(records) { $0.assignedToMe = true } == [2])
        #expect(visible(records) { $0.reviewRequested = true } == [4])
        #expect(Set(visible(records) { $0.unassigned = true; $0.assignedToMe = true }) == [1, 2])
    }

    @Test func assignedToMeMatchesAnyAccount() {
        let records = [record(1, .new, assignees: ["work"])]
        var filter = FilterSet()
        filter.assignedToMe = true
        #expect(numbers(ItemFilter.visible(records, filter: filter, viewers: ViewerLogins(["me", "work"]), scope: .all)) == [1])
        #expect(numbers(ItemFilter.visible(records, filter: filter, viewers: ViewerLogins(["me"]), scope: .all)).isEmpty)
    }

    @Test func kindsAndAttentionAreAndedAcrossGroups() {
        let records = [
            record(1, .new, kind: .issue),
            record(2, .new, kind: .pullRequest),
            record(3, .updated, kind: .pullRequest),
            record(4, .updated, kind: .pullRequest, assignees: ["me"]),
        ]
        #expect(Set(visible(records) { $0.pullRequests = true }) == [2, 3, 4])
        #expect(visible(records) { $0.issues = true } == [1])
        #expect(Set(visible(records) { $0.pullRequests = true; $0.issues = true }) == [1, 2, 3, 4])
        #expect(Set(visible(records) { $0.pullRequests = true; $0.new = false }) == [3, 4])
        #expect(visible(records) { $0.pullRequests = true; $0.new = false; $0.assignedToMe = true } == [4])
    }

    @Test func seenClosedItemIsNeverVisible() {
        let records = [record(1, .seen, status: .closed), record(2, .updated, status: .merged), record(3, .seen)]
        #expect(visible(records) == [2])
        #expect(Set(visible(records) { $0.new = false; $0.updated = false }) == [2, 3])
    }

    @Test func sortedByUpdatedAtNewestFirstWithStableTies() {
        let records = [
            record(1, .new, updatedAt: t0),
            record(2, .new, updatedAt: t2),
            record(5, .new, repo: 2, updatedAt: t1),
            record(4, .new, repo: 1, updatedAt: t1),
            record(3, .new, repo: 1, updatedAt: t1),
        ]
        let sorted = ItemFilter.visible(records, filter: FilterSet(), viewers: ViewerLogins(["me"]), scope: .all)
        #expect(sorted.map(\.item.key) == [
            ItemKey(repo: RepoID(rawValue: 1), number: 2),
            ItemKey(repo: RepoID(rawValue: 1), number: 3),
            ItemKey(repo: RepoID(rawValue: 1), number: 4),
            ItemKey(repo: RepoID(rawValue: 2), number: 5),
            ItemKey(repo: RepoID(rawValue: 1), number: 1),
        ])
    }

    @Test func botScope() {
        let records = [record(1, .new), record(2, .new, author: "dependabot", bot: true)]
        #expect(ItemFilter.scope(for: .badge) == .all)
        #expect(ItemFilter.scope(for: .grouped) == .humans)
        #expect(ItemFilter.scope(for: .hidden) == .humans)
        #expect(Set(visible(records, scope: .all)) == [1, 2])
        #expect(visible(records, scope: ItemFilter.scope(for: .grouped)) == [1])
        #expect(visible(records, scope: .bots) == [2])
    }

    @Test func countsExcludeBotsOnlyWhenHidden() {
        let records = [
            record(1, .new),
            record(2, .updated),
            record(3, .new, author: "renovate", bot: true),
            record(4, .seen),
            record(5, .updated, status: .closed),
        ]
        #expect(ItemFilter.counts(records, bots: .badge) == AttentionCounts(new: 2, updated: 2))
        #expect(ItemFilter.counts(records, bots: .grouped) == AttentionCounts(new: 2, updated: 2))
        #expect(ItemFilter.counts(records, bots: .hidden) == AttentionCounts(new: 1, updated: 2))
        #expect(ItemFilter.counts(records, bots: .hidden).total == 3)
    }

    @Test func kindCountsSplitByKind() {
        let records = [
            record(1, .new, kind: .pullRequest), record(2, .new, kind: .pullRequest), record(3, .updated, kind: .pullRequest),
            record(4, .new, kind: .issue), record(5, .seen, kind: .issue),
        ]
        let counts = ItemFilter.kindCounts(records, bots: .badge)
        #expect(counts.pullRequests == AttentionCounts(new: 2, updated: 1))
        #expect(counts.issues == AttentionCounts(new: 1, updated: 0))
        #expect(counts.total == ItemFilter.counts(records, bots: .badge))
    }

    @Test func kindCountsHiddenBotsLeftOut() {
        let records = [record(1, .new, kind: .pullRequest, author: "renovate", bot: true), record(2, .new, kind: .pullRequest)]
        #expect(ItemFilter.kindCounts(records, bots: .hidden).pullRequests == AttentionCounts(new: 1, updated: 0))
        #expect(ItemFilter.kindCounts(records, bots: .badge).pullRequests == AttentionCounts(new: 2, updated: 0))
    }

    @Test func filterSetDefaults() {
        let filter = FilterSet()
        #expect(filter.new && filter.updated)
        #expect(!filter.unassigned && !filter.assignedToMe && !filter.reviewRequested)
        #expect(!filter.pullRequests && !filter.issues)
    }
}
