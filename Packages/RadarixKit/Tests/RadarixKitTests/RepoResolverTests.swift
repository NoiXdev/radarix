import Testing
@testable import RadarixKit

struct RepoResolverTests {
    private let normal = RepoRef.fixture(id: 1, name: "b-normal")
    private let archived = RepoRef.fixture(id: 2, name: "a-archived", isArchived: true)
    private let fork = RepoRef.fixture(id: 3, name: "c-fork", isFork: true)
    private let other = RepoRef.fixture(id: 4, name: "D-other")
    private var available: [String: [RepoRef]] { ["o": [other, fork, archived, normal]] }

    @Test func allModeExcludesArchivedForksAndExcluded() {
        var c = WatchConfig()
        c.owners["o"] = .all(excluded: [RepoID(rawValue: 4)])
        let r = RepoResolver.watched(config: c, available: available)
        #expect(r.map(\.id.rawValue) == [1])
    }

    @Test func forksOnlyThroughSelectedMode() {
        var c = WatchConfig()
        c.owners["o"] = .selected([RepoID(rawValue: 3), RepoID(rawValue: 999)])
        #expect(RepoResolver.watched(config: c, available: available).map(\.id.rawValue) == [3])
        c.owners["o"] = .all(excluded: [])
        #expect(!RepoResolver.watched(config: c, available: available).contains { $0.isFork })
    }

    @Test func showArchivedIncludesArchived() {
        var c = WatchConfig()
        c.showArchived = true
        c.owners["o"] = .all(excluded: [])
        #expect(RepoResolver.watched(config: c, available: available).map(\.id.rawValue) == [2, 1, 4])
        c.owners["o"] = .selected([RepoID(rawValue: 2)])
        #expect(RepoResolver.watched(config: c, available: available).map(\.id.rawValue) == [2])
        c.showArchived = false
        #expect(RepoResolver.watched(config: c, available: available).isEmpty)
    }

    @Test func missingOwnerIsOff() {
        var c = WatchConfig()
        #expect(RepoResolver.watched(config: c, available: available).isEmpty)
        c.owners["o"] = .off
        #expect(RepoResolver.watched(config: c, available: available).isEmpty)
    }
}
