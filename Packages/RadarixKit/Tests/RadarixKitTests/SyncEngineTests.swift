import Foundation
import Testing
@testable import RadarixKit

/// Local clock of the machine, deliberately different from every server timestamp (t0, t1, t2).
private let localNow = t0.addingTimeInterval(600)

private let user = OwnerRef(login: "o", kind: .user)
private let org = OwnerRef(login: "acme", kind: .organization)
private let repoA = RepoRef.fixture(id: 1, name: "a")
private let repoB = RepoRef.fixture(id: 2, name: "b")
private let repoC = RepoRef.fixture(id: 3, owner: "acme", name: "c")

private func account(_ mode: OwnerMode = .all(excluded: []), repos: [RepoState] = []) -> AccountData {
    var a = AccountData(accountID: AccountID(rawValue: 42), login: "me")
    a.watch.owners["o"] = mode
    for state in repos { a.repos[state.repo.id] = state }
    return a
}

private func seen(_ item: Item, at date: Date = t0) -> ItemRecord {
    ItemRecord(item: item, attention: .seen, seenAt: date, commentsAtSeen: item.commentCount)
}

/// A repo already baselined at server time t0.
private func baselined(_ repo: RepoRef, _ records: [ItemRecord] = [], highWaterMark: Date? = t0) -> RepoState {
    RepoState(
        repo: repo, baselineAt: t0, highWaterMark: highWaterMark,
        records: Dictionary(uniqueKeysWithValues: records.map { ($0.item.key.number, $0) }))
}

private func run(
    _ api: StubGitHubAPI, _ account: AccountData,
    owners: [OwnerRef] = [user], previous: [String: [RepoRef]]? = nil
) async -> (AccountData, SyncReport) {
    let engine = SyncEngine(api: api, now: { localNow })
    let previous = previous ?? ["o": account.repos.values.map(\.repo).filter { $0.owner == "o" }]
    return await engine.sync(account, owners: owners, previousAvailable: previous)
}

private func itemQueries(_ api: StubGitHubAPI, repo: RepoRef) async -> [IssueQuery] {
    await api.calls.compactMap {
        if case .items(repo.id, let query) = $0 { return query }
        return nil
    }
}

struct SyncEngineTests {
    // MARK: Baseline

    @Test func baselineFetchesOpenItemsOnlyAndPages() async {
        let api = StubGitHubAPI()
        let items = (1...250).map { Item.fixture(number: $0, updatedAt: t0.addingTimeInterval(Double($0))) }
        await api.scriptRepositories("o", .success(.fresh([repoA])))
        await api.scriptItems(repoA, .success(.fresh(items)))

        let (result, report) = await run(api, account(), previous: [:])

        #expect(await itemQueries(api, repo: repoA) == [.openForBaseline])
        let state = result.repos[repoA.id]
        #expect(state?.records.count == 250)
        #expect(state?.records.values.allSatisfy { $0.attention == .seen } == true)
        #expect(state?.baselineAt == localNow)
        #expect(state?.highWaterMark == t0.addingTimeInterval(250))
        #expect(report.newItems.isEmpty)
        #expect(report.updatedItems.isEmpty)
    }

    @Test func baselineSeenAtUsesServerTime() async {
        let api = StubGitHubAPI()
        await api.scriptRepositories("o", .success(.fresh([repoA])))
        await api.scriptItems(repoA, .success(.fresh([.fixture(number: 1, updatedAt: t0), .fixture(number: 2, updatedAt: t1)])))

        let (result, _) = await run(api, account(), previous: [:])

        let state = result.repos[repoA.id]
        #expect(state?.records[1]?.seenAt == t1)
        #expect(state?.records[2]?.seenAt == t1)
        #expect(state?.highWaterMark == t1)
        #expect(state?.baselineAt == localNow)
    }

    @Test func emptyRepoBaselineUsesOverlap() async {
        let api = StubGitHubAPI()
        await api.scriptRepositories("o", .success(.fresh([repoA])))
        await api.scriptItems(repoA, .success(.fresh([])))

        let (first, firstReport) = await run(api, account(), previous: [:])
        #expect(first.repos[repoA.id]?.baselineAt == localNow)
        #expect(first.repos[repoA.id]?.highWaterMark == nil)

        let (second, secondReport) = await run(api, first, previous: firstReport.availableRepos)
        _ = await run(api, second, previous: secondReport.availableRepos)

        let overlap = localNow.addingTimeInterval(-300)
        #expect(await itemQueries(api, repo: repoA) == [.openForBaseline, .changed(since: overlap), .changed(since: overlap)])
    }

    @Test func baselineNotModifiedRetriesNextSync() async {
        let api = StubGitHubAPI()
        await api.scriptItems(repoA, .success(.notModified), .success(.fresh([.fixture(number: 1)])))
        let start = account(repos: [RepoState(repo: repoA)])

        let (first, _) = await run(api, start)
        #expect(first.repos[repoA.id]?.baselineAt == nil)

        let (second, _) = await run(api, first)
        #expect(await itemQueries(api, repo: repoA) == [.openForBaseline, .openForBaseline])
        #expect(second.repos[repoA.id]?.baselineAt == localNow)
        #expect(second.repos[repoA.id]?.records[1]?.attention == .seen)
    }

    // MARK: Conditional fetch

    @Test func unchangedRepoSendsSameURLAndGets304() async {
        let api = StubGitHubAPI()
        let item = Item.fixture(number: 1, updatedAt: t1)
        await api.scriptRepositories("o", .success(.fresh([repoA])))
        // `since` is inclusive: the second request returns the item with the same updatedAt, the third answers 304.
        await api.scriptItems(repoA, .success(.fresh([item])), .success(.fresh([item])), .success(.notModified))

        let (first, r1) = await run(api, account(), previous: [:])
        let (second, r2) = await run(api, first, previous: r1.availableRepos)
        let (third, r3) = await run(api, second, previous: r2.availableRepos)

        #expect(await itemQueries(api, repo: repoA) == [.openForBaseline, .changed(since: t1), .changed(since: t1)])
        #expect(third.repos[repoA.id]?.records == first.repos[repoA.id]?.records)
        #expect(third.repos[repoA.id]?.highWaterMark == t1)
        #expect(r2.newItems.isEmpty && r2.updatedItems.isEmpty && r3.newItems.isEmpty && r3.updatedItems.isEmpty)
        #expect(!(await api.calls).contains { if case .activity = $0 { true } else { false } })
    }

    // MARK: New and updated

    @Test func newItemByOtherIsReported() async {
        let api = StubGitHubAPI()
        let item = Item.fixture(number: 5, author: "alice", createdAt: t1, updatedAt: t1)
        await api.scriptItems(repoA, .success(.fresh([item])))

        let (result, report) = await run(api, account(repos: [baselined(repoA)]))

        #expect(report.newItems.map(\.key) == [item.key])
        #expect(report.updatedItems.isEmpty)
        #expect(result.repos[repoA.id]?.records[5]?.attention == .new)
        #expect(result.repos[repoA.id]?.highWaterMark == t1)
        #expect(await itemQueries(api, repo: repoA) == [.changed(since: t0)])
    }

    @Test func itemByViewerIsNotReported() async {
        let api = StubGitHubAPI()
        let item = Item.fixture(number: 5, author: "me", createdAt: t1, updatedAt: t1)
        await api.scriptItems(repoA, .success(.fresh([item])))

        let (result, report) = await run(api, account(repos: [baselined(repoA)]))

        #expect(report.newItems.isEmpty)
        #expect(report.updatedItems.isEmpty)
        #expect(result.repos[repoA.id]?.records[5]?.attention == .seen)
    }

    @Test func updatedOnlyAfterActivityCheck() async {
        let api = StubGitHubAPI()
        let one = Item.fixture(number: 1, updatedAt: t0)
        let two = Item.fixture(number: 2, updatedAt: t0)
        var movedOne = one
        movedOne.updatedAt = t1
        var movedTwo = two
        movedTwo.updatedAt = t1
        await api.scriptItems(repoA, .success(.fresh([movedOne, movedTwo])))
        await api.scriptActivity(1, .success(true))
        await api.scriptActivity(2, .success(false))

        let (result, report) = await run(api, account(repos: [baselined(repoA, [seen(one), seen(two)])]))

        #expect(report.updatedItems.map(\.key) == [one.key])
        #expect(report.newItems.isEmpty)
        let records = result.repos[repoA.id]?.records
        #expect(records?[1]?.attention == .updated)
        #expect(records?[2]?.attention == .seen)
        #expect(records?[2]?.seenAt == t1)
        let probes = await api.calls.filter { if case .activity = $0 { true } else { false } }
        #expect(probes == [.activity(number: 1, since: t0, viewer: "me"), .activity(number: 2, since: t0, viewer: "me")])
    }

    @Test func probeErrorTreatsItemAsUpdated() async {
        let api = StubGitHubAPI()
        let item = Item.fixture(number: 1, updatedAt: t0)
        var moved = item
        moved.updatedAt = t1
        await api.scriptItems(repoA, .success(.fresh([moved])))
        await api.scriptActivity(1, .failure(.network("timeout")))

        let (result, report) = await run(api, account(repos: [baselined(repoA, [seen(item)])]))

        #expect(report.updatedItems.map(\.key) == [item.key])
        #expect(report.repoFailures.isEmpty)
        #expect(result.repos[repoA.id]?.records[1]?.attention == .updated)
    }

    @Test func preExistingItemIsNotReportedAsNew() async {
        let api = StubGitHubAPI()
        // Created before the repo was watched (baselineAt t1), closed at baseline time, reopened at t2.
        let reopened = Item.fixture(number: 9, author: "alice", commentCount: 4, createdAt: t0, updatedAt: t2)
        await api.scriptItems(repoA, .success(.fresh([reopened])))
        await api.scriptActivity(9, .success(true))
        var state = baselined(repoA, highWaterMark: t1)
        state.baselineAt = t1

        let (result, report) = await run(api, account(repos: [state]))

        #expect(report.newItems.isEmpty)
        #expect(report.updatedItems.map(\.key) == [reopened.key])
        let record = result.repos[repoA.id]?.records[9]
        #expect(record?.attention == .updated)
        #expect(record?.commentsAtSeen == 0)
        #expect(record?.seenAt == t1)
        #expect(await api.calls.contains(.activity(number: 9, since: t1, viewer: "me")))
    }

    // MARK: Pull details

    @Test func pullDetailsMergedIntoRecords() async {
        let api = StubGitHubAPI()
        let pr1 = Item.fixture(number: 1, kind: .pullRequest)
        let pr2 = Item.fixture(number: 2, kind: .pullRequest, isDraft: true, requestedReviewers: ["carol"])
        let merged = Item.fixture(number: 3, kind: .pullRequest, status: .merged, isDraft: true)
        let issue = Item.fixture(number: 4)
        var pr2Updated = seen(pr2)
        pr2Updated.attention = .updated
        let start = account(repos: [baselined(repoA, [seen(pr1), pr2Updated, seen(merged), seen(issue)])])
        await api.scriptPullDetails(repoA, .success(.fresh([1: PullDetails(isDraft: true, requestedReviewers: ["bob"])])))

        let (result, _) = await run(api, start)

        let records = result.repos[repoA.id]?.records
        #expect(records?[1]?.item.isDraft == true)
        #expect(records?[1]?.item.requestedReviewers == ["bob"])
        #expect(records?[2]?.item.isDraft == false)
        #expect(records?[2]?.item.requestedReviewers == [])
        #expect(records?[2]?.attention == .updated)
        #expect(records?[2]?.item.updatedAt == t0)
        #expect(records?[3] == start.repos[repoA.id]?.records[3])
        #expect(records?[4] == start.repos[repoA.id]?.records[4])

        // 304 on the pulls list leaves the merged details in place.
        let (again, _) = await run(api, result)
        #expect(again.repos[repoA.id]?.records == records)
    }

    @Test func pullDetailsSurviveItemUpdate() async {
        let api = StubGitHubAPI()
        let pr = Item.fixture(number: 1, kind: .pullRequest, isDraft: true, requestedReviewers: ["bob"])
        var moved = Item.fixture(number: 1, kind: .pullRequest, updatedAt: t1)
        moved.title = "Retitled"
        await api.scriptItems(repoA, .success(.fresh([moved])))

        let (result, _) = await run(api, account(repos: [baselined(repoA, [seen(pr)])]))

        let record = result.repos[repoA.id]?.records[1]
        #expect(record?.item.title == "Retitled")
        #expect(record?.item.isDraft == true)
        #expect(record?.item.requestedReviewers == ["bob"])
    }

    // MARK: Watch changes

    @Test func unwatchedRepoStateDropped() async {
        let api = StubGitHubAPI()
        await api.scriptRepositories("o", .success(.fresh([repoA, repoB])))
        let start = account(.selected([repoA.id]), repos: [baselined(repoA), baselined(repoB)])

        let (result, _) = await run(api, start)

        #expect(Set(result.repos.keys) == [repoA.id])
        #expect(await itemQueries(api, repo: repoB).isEmpty)
    }

    @Test func rewatchedRepoGetsFreshBaseline() async {
        let api = StubGitHubAPI()
        await api.scriptRepositories("o", .success(.fresh([repoA, repoB])))
        let old = Item.fixture(repo: 2, number: 7, author: "alice", createdAt: t0, updatedAt: t0)
        await api.scriptItems(repoB, .success(.fresh([old])))
        let start = account(.selected([repoA.id]), repos: [baselined(repoA), baselined(repoB)])

        let (dropped, r1) = await run(api, start)
        var rewatched = dropped
        rewatched.watch.owners["o"] = .selected([repoA.id, repoB.id])
        let (result, r2) = await run(api, rewatched, previous: r1.availableRepos)

        #expect(await itemQueries(api, repo: repoB) == [.openForBaseline])
        #expect(result.repos[repoB.id]?.baselineAt == localNow)
        #expect(result.repos[repoB.id]?.records[7]?.attention == .seen)
        #expect(r2.newItems.isEmpty)
    }

    @Test func renamedRepoKeepsState() async {
        let api = StubGitHubAPI()
        let renamed = RepoRef.fixture(id: 1, name: "renamed")
        let item = Item.fixture(number: 1)
        await api.scriptRepositories("o", .success(.fresh([renamed])))

        let (result, _) = await run(api, account(repos: [baselined(repoA, [seen(item)])]))

        #expect(result.repos[repoA.id]?.repo.name == "renamed")
        #expect(result.repos[repoA.id]?.records[1] == seen(item))
    }

    @Test func ownerWithoutRepoListKeepsState() async {
        let api = StubGitHubAPI()
        await api.scriptRepositories("o", .failure(.network("offline")))
        let start = account(repos: [baselined(repoA, [seen(.fixture(number: 1))])])

        let (result, report) = await run(api, start, previous: [:])

        #expect(result.repos == start.repos)
        #expect(report.availableRepos["o"] == nil)
        #expect(await itemQueries(api, repo: repoA).isEmpty)
    }

    // MARK: Errors

    @Test func unauthorizedKeepsDataAndFlagsReauth() async {
        let api = StubGitHubAPI()
        let newOne = Item.fixture(number: 5, author: "alice", createdAt: t1, updatedAt: t1)
        await api.scriptItems(repoA, .success(.fresh([newOne])))
        await api.scriptItems(repoB, .failure(.unauthorized))
        let start = account(repos: [baselined(repoA), baselined(repoB, [seen(.fixture(repo: 2, number: 1))])])

        let (result, report) = await run(api, start)

        #expect(report.needsReauth)
        #expect(result.repos[repoA.id]?.records[5]?.attention == .new)
        #expect(result.repos[repoB.id] == start.repos[repoB.id])
        #expect(report.repoFailures.isEmpty)
        #expect(await api.calls.last == .items(repo: repoB.id, query: .changed(since: t0)))

        // On the repo list, nothing has been synced yet: the account comes back unchanged.
        let listAPI = StubGitHubAPI()
        await listAPI.scriptRepositories("o", .failure(.unauthorized))
        let (unchanged, listReport) = await run(listAPI, start)
        #expect(unchanged == start)
        #expect(listReport.needsReauth)
        #expect(await listAPI.calls == [.repositories(owner: "o")])
    }

    @Test func rateLimitedStopsAndReportsReset() async {
        let api = StubGitHubAPI()
        let item = Item.fixture(number: 1, updatedAt: t0)
        var moved = item
        moved.updatedAt = t1
        await api.scriptItems(repoA, .success(.fresh([moved, .fixture(number: 2, author: "alice", createdAt: t1, updatedAt: t1)])))
        await api.scriptActivity(1, .failure(.rateLimited(resetAt: t2)))
        let limit = RateLimit(limit: 5000, remaining: 0, resetAt: t2)
        await api.setRateLimit(limit)
        let start = account(repos: [baselined(repoA, [seen(item)]), baselined(repoB)])

        let (result, report) = await run(api, start)

        #expect(report.rateLimitedUntil == t2)
        #expect(report.rateLimit == limit)
        #expect(await api.calls.last == .activity(number: 1, since: t0, viewer: "me"))
        #expect(await itemQueries(api, repo: repoB).isEmpty)
        #expect(result.repos == start.repos)
        #expect(report.newItems.isEmpty && report.updatedItems.isEmpty)
    }

    @Test func networkErrorKeepsPreviousItems() async {
        let api = StubGitHubAPI()
        let kept = seen(.fixture(number: 1))
        await api.scriptItems(repoA, .failure(.network("offline")))
        let newOne = Item.fixture(repo: 2, number: 5, author: "alice", createdAt: t1, updatedAt: t1)
        await api.scriptItems(repoB, .success(.fresh([newOne])))
        var stateB = baselined(repoB)
        stateB.lastFailure = "earlier failure"

        let (result, report) = await run(api, account(repos: [baselined(repoA, [kept]), stateB]))

        #expect(report.repoFailures == [repoA.id: .network("offline")])
        #expect(result.repos[repoA.id]?.records == [1: kept])
        #expect(result.repos[repoA.id]?.lastFailure != nil)
        #expect(result.repos[repoB.id]?.records[5]?.attention == .new)
        #expect(result.repos[repoB.id]?.lastFailure == nil)
        #expect(report.newItems.map(\.key) == [newOne.key])
    }

    @Test func pullDetailsErrorKeepsItemChanges() async {
        let newOne = Item.fixture(number: 5, author: "alice", createdAt: t1, updatedAt: t1)
        let start = account(repos: [baselined(repoA)])

        // A plain failure on the pulls list: the repo is marked failed, the new item is kept and reported.
        let api = StubGitHubAPI()
        await api.scriptItems(repoA, .success(.fresh([newOne])))
        await api.scriptPullDetails(repoA, .failure(.http(502)))
        let (failed, failedReport) = await run(api, start)
        #expect(failedReport.repoFailures == [repoA.id: .http(502)])
        #expect(failed.repos[repoA.id]?.records[5]?.attention == .new)
        #expect(failed.repos[repoA.id]?.highWaterMark == t1)
        #expect(failedReport.newItems.map(\.key) == [newOne.key])

        // A stop on the pulls list: the items committed before it are kept and reported too.
        let stopAPI = StubGitHubAPI()
        await stopAPI.scriptItems(repoA, .success(.fresh([newOne])))
        await stopAPI.scriptPullDetails(repoA, .failure(.unauthorized))
        let (stopped, stopReport) = await run(stopAPI, start)
        #expect(stopReport.needsReauth)
        #expect(stopped.repos[repoA.id]?.records[5]?.attention == .new)
        #expect(stopReport.newItems.map(\.key) == [newOne.key])
    }

    @Test func repoErrorsMapToSyncFailures() async {
        let api = StubGitHubAPI()
        await api.scriptItems(repoA, .failure(.forbidden("nope")))
        await api.scriptItems(repoB, .failure(.notFound))

        let (_, report) = await run(api, account(repos: [baselined(repoA), baselined(repoB)]))

        #expect(report.repoFailures == [repoA.id: .http(403), repoB.id: .notFound])
    }

    @Test func orgReposForbiddenBecomesAccessIssue() async {
        let api = StubGitHubAPI()
        await api.scriptRepositories("acme", .failure(.forbidden("SAML enforcement")))
        var start = account(repos: [baselined(repoC)])
        start.watch.owners["acme"] = .all(excluded: [])
        start.watch.owners["off-org"] = .off
        let offOrg = OwnerRef(login: "off-org", kind: .organization)

        let (result, report) = await run(
            api, start, owners: [user, org, offOrg],
            previous: ["o": [], "acme": [repoC], "off-org": [RepoRef.fixture(id: 9, owner: "off-org")]])

        #expect(report.ownerIssues == ["acme": .restricted(message: "SAML enforcement")])
        #expect(report.availableRepos == ["o": [], "acme": [repoC]])
        #expect(result.repos[repoC.id] != nil)
        #expect(await itemQueries(api, repo: repoC) == [.changed(since: t0)])
        #expect(!(await api.calls).contains(.repositories(owner: "off-org")))
        #expect(report.repoFailures.isEmpty)
    }
}
