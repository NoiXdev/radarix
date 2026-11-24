import Foundation
import Testing
@testable import RadarixKit

private func item(_ number: Int, repo: Int64 = 1, bot: Bool = false, updatedAt: Date = t0) -> Item {
    var item = Item.fixture(repo: repo, number: number, updatedAt: updatedAt)
    if bot { item.author = Actor(login: "dependabot[bot]", apiType: "Bot") }
    return item
}

private func account(repos: [Int64] = [1], off: Set<RepoID> = []) -> AccountData {
    var watch = WatchConfig()
    watch.notificationsOff = off
    var data = AccountData(accountID: AccountID(rawValue: 1), login: "me", watch: watch)
    for id in repos {
        let ref = RepoRef.fixture(id: id)
        data.repos[ref.id] = RepoState(repo: ref)
    }
    return data
}

private func report(new: [Item] = [], updated: [Item] = []) -> SyncReport {
    var report = SyncReport()
    report.newItems = new
    report.updatedItems = updated
    return report
}

struct NotificationPlannerTests {
    @Test func newItemNotifies() {
        let planned = NotificationPlanner.plan(report(new: [item(1)]), account: account(), settings: AppSettings())
        #expect(planned.count == 1)
        #expect(planned[0].content == .item(item(1), .new))
    }

    @Test func updatedNotifiesOnlyWhenEnabled() {
        let r = report(updated: [item(1)])
        #expect(NotificationPlanner.plan(r, account: account(), settings: AppSettings()).isEmpty)
        var settings = AppSettings()
        settings.notifyUpdated = true
        let planned = NotificationPlanner.plan(r, account: account(), settings: settings)
        #expect(planned.map(\.content) == [.item(item(1), .updated)])
    }

    @Test func itemInBothListsCountsOnceAsNew() {
        var settings = AppSettings()
        settings.notifyUpdated = true
        let planned = NotificationPlanner.plan(
            report(new: [item(1)], updated: [item(1)]), account: account(), settings: settings)
        #expect(planned.map(\.content) == [.item(item(1), .new)])
    }

    @Test func repoWithNotificationsOffIsSilent() {
        let acc = account(repos: [1, 2], off: [RepoID(rawValue: 1)])
        let planned = NotificationPlanner.plan(
            report(new: [item(1, repo: 1), item(2, repo: 2)]), account: acc, settings: AppSettings())
        #expect(planned.map(\.id) == ["item-2-2"])
    }

    @Test func unknownRepoIsDropped() {
        let planned = NotificationPlanner.plan(report(new: [item(1, repo: 9)]), account: account(), settings: AppSettings())
        #expect(planned.isEmpty)
    }

    @Test func botsSilentByDefault() {
        let planned = NotificationPlanner.plan(report(new: [item(1, bot: true)]), account: account(), settings: AppSettings())
        #expect(planned.isEmpty)
    }

    @Test func botsNotifyWhenEnabled() {
        var settings = AppSettings()
        settings.notifyBots = true
        let planned = NotificationPlanner.plan(report(new: [item(1, bot: true)]), account: account(), settings: settings)
        #expect(planned.count == 1)
    }

    @Test func hiddenBotsNeverNotify() {
        var settings = AppSettings()
        settings.notifyBots = true
        settings.botDisplay = .hidden
        let planned = NotificationPlanner.plan(
            report(new: [item(1, bot: true), item(2)]), account: account(), settings: settings)
        #expect(planned.map(\.id) == ["item-1-2"])
    }

    @Test func manyNewItemsInOneRepoBecomeOneSummary() {
        let repo = RepoRef.fixture(id: 1)
        let four = NotificationPlanner.plan(
            report(new: (1...4).map { item($0) }), account: account(), settings: AppSettings())
        #expect(four.count == 1)
        #expect(four[0].id == "repo-1")
        #expect(four[0].content == .summary(repo: repo, newCount: 4, updatedCount: 0))
        let three = NotificationPlanner.plan(
            report(new: (1...3).map { item($0) }), account: account(), settings: AppSettings())
        #expect(three.count == 3)
    }

    @Test func summaryCountsUpdatedSeparately() {
        var settings = AppSettings()
        settings.notifyUpdated = true
        let planned = NotificationPlanner.plan(
            report(new: [item(1), item(2)], updated: [item(3), item(4)]), account: account(), settings: settings)
        #expect(planned.map(\.content) == [.summary(repo: RepoRef.fixture(id: 1), newCount: 2, updatedCount: 2)])
    }

    @Test func emptyReportPlansNothing() {
        #expect(NotificationPlanner.plan(SyncReport(), account: account(), settings: AppSettings()).isEmpty)
    }

    @Test func ordersByRepoNameThenNewestFirst() {
        var acc = account(repos: [])
        for (id, name) in [(Int64(1), "zeta"), (2, "Alpha")] {
            let ref = RepoRef.fixture(id: id, name: name)
            acc.repos[ref.id] = RepoState(repo: ref)
        }
        let planned = NotificationPlanner.plan(
            report(new: [item(1, repo: 1), item(2, repo: 2, updatedAt: t0), item(3, repo: 2, updatedAt: t1)]),
            account: acc, settings: AppSettings())
        #expect(planned.map(\.id) == ["item-2-3", "item-2-2", "item-1-1"])
    }

    @Test func idsAreStable() {
        let r = report(new: (1...5).map { item($0, repo: 1) } + [item(7, repo: 2), item(6, repo: 2)])
        let acc = account(repos: [1, 2])
        let first = NotificationPlanner.plan(r, account: acc, settings: AppSettings())
        let second = NotificationPlanner.plan(r, account: acc, settings: AppSettings())
        #expect(first == second)
        #expect(first.map(\.id) == ["repo-1", "item-2-6", "item-2-7"])
    }
}
