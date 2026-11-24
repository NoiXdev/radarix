import Foundation
import Testing
@testable import RadarixKit

private let signedIn = AuthState.signedIn(login: "me")

private func rec(
    _ number: Int, _ attention: Attention, repo: Int64 = 1, status: ItemStatus = .open,
    author: String = "alice", updatedAt: Date = t1
) -> ItemRecord {
    ItemRecord(
        item: .fixture(repo: repo, number: number, author: author, status: status, updatedAt: updatedAt),
        attention: attention, seenAt: attention == .seen ? t0 : nil, commentsAtSeen: 0)
}

private func account(_ repos: [(RepoRef, [ItemRecord])]) -> AccountData {
    var a = AccountData(accountID: AccountID(rawValue: 42), login: "me")
    for (repo, records) in repos {
        a.repos[repo.id] = RepoState(
            repo: repo, baselineAt: t0,
            records: Dictionary(uniqueKeysWithValues: records.map { ($0.item.key.number, $0) }))
    }
    return a
}

private func settings(_ bots: BotDisplayMode) -> AppSettings {
    var s = AppSettings()
    s.botDisplay = bots
    return s
}

private func snapshot(_ repos: [(RepoRef, [ItemRecord])], bots: BotDisplayMode = .badge) -> WidgetSnapshot {
    WidgetSnapshot.make(account: account(repos), settings: settings(bots), auth: signedIn, syncedAt: t2)
}

struct WidgetSnapshotTests {
    @Test func countsOnlyListedNewAndUpdated() throws {
        let repo = RepoRef.fixture(id: 1)
        let s = snapshot([(repo, [
            rec(1, .new), rec(2, .updated), rec(3, .seen), rec(4, .seen, status: .closed),
            rec(5, .new, status: .closed), rec(6, .updated, status: .merged),
        ])])
        let entry = try #require(s.repos.first)
        #expect(s.repos.count == 1)
        #expect(entry.newCount == 2)
        #expect(entry.updatedCount == 2)
        #expect(Set(entry.items.map(\.key.number)) == [1, 2, 5, 6])
        #expect(entry.fullName == "o/repo1")
        #expect(s.status == .ok)
        #expect(s.login == "me")
        #expect(s.syncedAt == t2)
    }

    @Test func keepsNewestSixPerRepo() throws {
        let repo = RepoRef.fixture(id: 1)
        // Items 1...8, item n updated n minutes after t0; items 9 and 10 tie with item 8.
        var records = (1...8).map { rec($0, .new, updatedAt: t0.addingTimeInterval(Double($0) * 60)) }
        records += [9, 10].map { rec($0, .updated, updatedAt: t0.addingTimeInterval(8 * 60)) }
        let entry = try #require(snapshot([(repo, records)]).repos.first)
        #expect(WidgetSnapshot.itemsPerRepo == 6)
        #expect(entry.newCount == 8)
        #expect(entry.updatedCount == 2)
        #expect(entry.items.map(\.key.number) == [8, 9, 10, 7, 6, 5])
    }

    @Test func itemEntryCarriesTheItemFields() throws {
        let repo = RepoRef.fixture(id: 1)
        let pull = ItemRecord(
            item: .fixture(number: 1, kind: .pullRequest, title: "Bump deps", author: "renovate[bot]", isDraft: true, updatedAt: t2),
            attention: .updated, seenAt: t0, commentsAtSeen: 0)
        let entry = try #require(snapshot([(repo, [pull])]).repos.first?.items.first)
        #expect(entry == WidgetSnapshot.ItemEntry(
            key: ItemKey(repo: repo.id, number: 1), kind: .pullRequest, title: "Bump deps",
            attention: .updated, updatedAt: t2, isDraft: true, botName: "Renovate"))
        #expect(entry.id == entry.key)
    }

    @Test func hiddenBotsExcludedFromSnapshot() throws {
        let repo = RepoRef.fixture(id: 1)
        let records = [rec(1, .new), rec(2, .new, author: "dependabot[bot]"), rec(3, .updated, author: "dependabot[bot]")]

        let hidden = try #require(snapshot([(repo, records)], bots: .hidden).repos.first)
        #expect(hidden.newCount == 1)
        #expect(hidden.updatedCount == 0)
        #expect(hidden.items.map(\.key.number) == [1])

        for mode in [BotDisplayMode.badge, .grouped] {
            let shown = try #require(snapshot([(repo, records)], bots: mode).repos.first)
            #expect(shown.newCount == 2)
            #expect(shown.updatedCount == 1)
            #expect(shown.items.filter { $0.botName == "Dependabot" }.map(\.key.number).sorted() == [2, 3])
            #expect(shown.items.first { $0.key.number == 1 }?.botName == nil)
        }
    }

    @Test func summaryForOwnerAndRepoScopes() {
        let a = RepoRef.fixture(id: 1, owner: "o", name: "a")
        let b = RepoRef.fixture(id: 2, owner: "Acme", name: "b")
        let c = RepoRef.fixture(id: 3, owner: "acme", name: "c")
        let s = snapshot([
            (a, [rec(1, .new, repo: 1, updatedAt: t1)]),
            (b, [rec(1, .new, repo: 2, updatedAt: t2), rec(2, .updated, repo: 2, updatedAt: t0)]),
            (c, [rec(1, .seen, repo: 3)]),
        ])

        #expect(s.owners == ["Acme", "acme", "o"])

        let all = s.summary(for: .all)
        #expect(all.newCount == 2)
        #expect(all.updatedCount == 1)
        #expect(all.repos.map(\.id) == [b.id, a.id, c.id])
        #expect(all.items.map(\.key) == [
            ItemKey(repo: b.id, number: 1), ItemKey(repo: a.id, number: 1), ItemKey(repo: b.id, number: 2),
        ])

        let acme = s.summary(for: .owner("ACME"))
        #expect(acme.repos.map(\.id) == [b.id, c.id])
        #expect(acme.newCount == 1)
        #expect(acme.updatedCount == 1)
        #expect(acme.items.map(\.key) == [ItemKey(repo: b.id, number: 1), ItemKey(repo: b.id, number: 2)])

        let onlyA = s.summary(for: .repo(a.id))
        #expect(onlyA.repos.map(\.id) == [a.id])
        #expect(onlyA.newCount == 1)
        #expect(onlyA.updatedCount == 0)
        #expect(onlyA.items.map(\.key) == [ItemKey(repo: a.id, number: 1)])

        let unknown = s.summary(for: .repo(RepoID(rawValue: 99)))
        #expect(unknown.repos.isEmpty)
        #expect(unknown.items.isEmpty)
        #expect(unknown.newCount == 0 && unknown.updatedCount == 0)
        #expect(unknown.busiestRepo == nil)
        #expect(s.summary(for: .owner("nobody")).repos.isEmpty)
    }

    @Test func busiestRepoIsLargestTotal() {
        let quiet = RepoRef.fixture(id: 1, name: "a")
        let small = RepoRef.fixture(id: 2, name: "b")
        let tieLater = RepoRef.fixture(id: 3, name: "d")
        let tieFirst = RepoRef.fixture(id: 4, name: "c")
        let s = snapshot([
            (quiet, [rec(1, .seen, repo: 1)]),
            (small, [rec(1, .new, repo: 2)]),
            (tieLater, [rec(1, .new, repo: 3), rec(2, .updated, repo: 3)]),
            (tieFirst, [rec(1, .updated, repo: 4), rec(2, .updated, repo: 4)]),
        ])
        let all = s.summary(for: .all)
        #expect(all.repos.map(\.name) == ["c", "d", "b", "a"])
        #expect(all.busiestRepo?.id == tieFirst.id)

        let idle = snapshot([(quiet, [rec(1, .seen, repo: 1)])])
        #expect(idle.repos.count == 1)
        #expect(idle.summary(for: .all).busiestRepo == nil)
    }

    @Test func statusFollowsAuth() {
        let a = account([])
        #expect(WidgetSnapshot.make(account: a, settings: AppSettings(), auth: .needsReauth(login: "me"), syncedAt: nil).status == .needsReauth)
        #expect(WidgetSnapshot.make(account: a, settings: AppSettings(), auth: .signedOut, syncedAt: nil).status == .signedOut)
        #expect(WidgetSnapshot.signedOut == WidgetSnapshot(status: .signedOut, login: nil, syncedAt: nil, repos: []))
    }

    @Test func snapshotJSONHasOnlyKnownKeys() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let repo = RepoRef.fixture(id: 1)
        let s = snapshot([(repo, [rec(1, .new, author: "dependabot[bot]"), rec(2, .updated)])])
        try FileStore(directory: dir).saveSnapshot(s)

        let data = try Data(contentsOf: dir.appending(path: "widget-snapshot.json"))
        var paths: Set<String> = []
        collectKeyPaths(try JSONSerialization.jsonObject(with: data), prefix: "", into: &paths)
        #expect(paths == [
            "status", "login", "syncedAt", "repos",
            "repos.id", "repos.id.rawValue", "repos.owner", "repos.name", "repos.newCount", "repos.updatedCount",
            "repos.items", "repos.items.key", "repos.items.key.repo", "repos.items.key.repo.rawValue",
            "repos.items.key.number", "repos.items.kind", "repos.items.title", "repos.items.attention",
            "repos.items.updatedAt", "repos.items.isDraft", "repos.items.botName",
        ])
    }

    @Test func snapshotMatchesControllerCounts() {
        let a = RepoRef.fixture(id: 1, name: "a")
        let b = RepoRef.fixture(id: 2, owner: "p", name: "b")
        let repos: [(RepoRef, [ItemRecord])] = [
            (a, [
                rec(1, .new), rec(2, .updated), rec(3, .seen), rec(4, .seen, status: .closed),
                rec(5, .new, author: "dependabot[bot]"), rec(6, .updated, status: .closed, author: "renovate[bot]"),
            ]),
            (b, [rec(1, .new, repo: 2), rec(2, .seen, repo: 2, author: "dependabot[bot]"), rec(3, .new, repo: 2, status: .merged)]),
        ]
        let allRecords = account(repos).repos.values.flatMap { $0.records.values }
        for mode in [BotDisplayMode.badge, .grouped, .hidden] {
            let summary = snapshot(repos, bots: mode).summary(for: .all)
            let counts = ItemFilter.counts(allRecords, bots: mode)
            #expect(summary.newCount == counts.new, "\(mode)")
            #expect(summary.updatedCount == counts.updated, "\(mode)")
            #expect(summary.items.count == counts.total, "\(mode)")
        }
    }
}

private func collectKeyPaths(_ value: Any, prefix: String, into paths: inout Set<String>) {
    if let object = value as? [String: Any] {
        for (key, child) in object {
            let path = prefix.isEmpty ? key : "\(prefix).\(key)"
            paths.insert(path)
            collectKeyPaths(child, prefix: path, into: &paths)
        }
    } else if let array = value as? [Any] {
        for element in array { collectKeyPaths(element, prefix: prefix, into: &paths) }
    }
}
