import Testing
@testable import RadarixKit

struct RepoOwnershipTests {
    private let r1 = RepoRef.fixture(id: 1, name: "one")
    private let r2 = RepoRef.fixture(id: 2, name: "two")
    private let first = AccountID(rawValue: 10)
    private let second = AccountID(rawValue: 20)

    @Test func firstAccountWins() {
        let owners = RepoOwnership.assign([(first, [r1]), (second, [r1, r2])])
        #expect(owners == [r1.id: first, r2.id: second])
    }

    @Test func emptyInputGivesEmptyMap() {
        #expect(RepoOwnership.assign([]).isEmpty)
    }

    @Test func orderNotIdDecides() {
        let owners = RepoOwnership.assign([(second, [r1]), (first, [r1])])
        #expect(owners == [r1.id: second])
    }
}
