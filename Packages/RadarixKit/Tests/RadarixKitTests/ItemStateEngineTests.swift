import Foundation
import Testing
@testable import RadarixKit

private func record(
    _ attention: Attention,
    updatedAt: Date = t0,
    seenAt: Date? = t0,
    comments: Int = 0,
    commentsAtSeen: Int = 0,
    status: ItemStatus = .open
) -> ItemRecord {
    ItemRecord(
        item: .fixture(status: status, commentCount: comments, updatedAt: updatedAt),
        attention: attention,
        seenAt: seenAt,
        commentsAtSeen: commentsAtSeen
    )
}

@Test func baselineMarksEverythingSeen() {
    let recs = ItemStateEngine.baseline([.fixture(number: 1, commentCount: 3)], at: t0)
    #expect(recs[0].attention == .seen && recs[0].seenAt == t0 && recs[0].commentsAtSeen == 3)
}

@Test func unknownItemByOtherIsNew() {
    #expect(ItemStateEngine.apply(fetched: .fixture(author: "alice"), previous: nil, viewer: "me", otherActivity: nil).attention == .new)
}

@Test func unknownItemByViewerIsSeen() {
    #expect(ItemStateEngine.apply(fetched: .fixture(author: "me"), previous: nil, viewer: "me", otherActivity: nil).attention == .seen)
}

@Test func newStaysNewWhenItChanges() {
    let result = ItemStateEngine.apply(
        fetched: .fixture(updatedAt: t1), previous: record(.new, seenAt: nil), viewer: "me", otherActivity: true)
    #expect(result.attention == .new)
    #expect(result.item.updatedAt == t1)
}

@Test func seenBecomesUpdatedOnOtherActivity() {
    let result = ItemStateEngine.apply(
        fetched: .fixture(commentCount: 2, updatedAt: t1), previous: record(.seen), viewer: "me", otherActivity: true)
    #expect(result.attention == .updated)
    #expect(result.seenAt == t0)
    #expect(result.commentsAtSeen == 0)
    #expect(result.newComments == 2)
}

@Test func seenStaysSeenOnOwnActivity() {
    let result = ItemStateEngine.apply(
        fetched: .fixture(updatedAt: t1), previous: record(.seen), viewer: "me", otherActivity: false)
    #expect(result.attention == .seen)
    #expect(result.seenAt == t1)
}

@Test func unknownActivityCountsAsUpdated() {
    let fetched = Item.fixture(updatedAt: t1)
    let previous = record(.seen)
    #expect(ItemStateEngine.needsActivityCheck(previous: previous, fetched: fetched))
    let result = ItemStateEngine.apply(fetched: fetched, previous: previous, viewer: "me", otherActivity: nil)
    #expect(result.attention == .updated)
}

@Test func unchangedItemKeepsAttention() {
    let result = ItemStateEngine.apply(
        fetched: .fixture(title: "Renamed", updatedAt: t0), previous: record(.seen), viewer: "me", otherActivity: nil)
    #expect(result.attention == .seen)
    #expect(result.item.title == "Renamed")
}

@Test func markSeenResetsCounters() {
    let rec = record(.updated, comments: 5, commentsAtSeen: 1)
    let result = ItemStateEngine.markSeen(rec, at: t2)
    #expect(result.attention == .seen)
    #expect(result.seenAt == t2)
    #expect(result.commentsAtSeen == 5)
}

@Test func markUnseenMakesUpdated() {
    #expect(ItemStateEngine.markUnseen(record(.seen)).attention == .updated)
}

@Test func closedSeenItemIsNotListed() {
    #expect(!ItemStateEngine.isListed(.init(item: .fixture(status: .closed), attention: .seen, seenAt: t0, commentsAtSeen: 0)))
    #expect(ItemStateEngine.isListed(.init(item: .fixture(status: .merged), attention: .new, seenAt: nil, commentsAtSeen: 0)))
}

@Test func needsActivityCheckOnlyForSeenItemsThatMoved() {
    let moved = Item.fixture(updatedAt: t1)
    #expect(ItemStateEngine.needsActivityCheck(previous: record(.seen), fetched: moved))
    #expect(!ItemStateEngine.needsActivityCheck(previous: record(.new, seenAt: nil), fetched: moved))
    #expect(!ItemStateEngine.needsActivityCheck(previous: record(.seen), fetched: .fixture(updatedAt: t0)))
    #expect(!ItemStateEngine.needsActivityCheck(previous: nil, fetched: moved))
}
