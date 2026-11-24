import Foundation
import Testing
@testable import RadarixKit

private let base = "https://api.github.com"
private let repo = RepoRef(id: RepoID(rawValue: 1296269), owner: "octo", name: "hello-world", isPrivate: false, isArchived: false, isFork: false)

private func makeClient(_ stub: StubTransport) -> GitHubClient {
    GitHubClient(token: "tok", transport: stub)
}

@Suite struct GitHubAPITests {
    @Test func viewerDecodes() async throws {
        let stub = StubTransport()
        await stub.enqueue("\(base)/user", status: 200, body: try fixtureJSON("user"))
        let viewer = try await makeClient(stub).viewer()
        #expect(viewer == Viewer(id: AccountID(rawValue: 583231), login: "octo"))
    }

    @Test func ownersAreUserPlusOrgs() async throws {
        let stub = StubTransport()
        await stub.enqueue("\(base)/user", status: 200, body: try fixtureJSON("user"))
        await stub.enqueue("\(base)/user/orgs?per_page=100", status: 200, body: try fixtureJSON("orgs"))
        let owners = try await makeClient(stub).owners()
        #expect(owners == [
            OwnerRef(login: "octo", kind: .user),
            OwnerRef(login: "acme", kind: .organization),
            OwnerRef(login: "globex", kind: .organization),
        ])
    }

    @Test func userReposUseOwnerAffiliation() async throws {
        let stub = StubTransport()
        await stub.enqueue("\(base)/user/repos?affiliation=owner&per_page=100", status: 200, body: try fixtureJSON("repos"))
        await stub.enqueue("\(base)/orgs/acme/repos?type=all&per_page=100", status: 200, body: try fixtureJSON("repos"))
        let client = makeClient(stub)

        guard case .fresh(let repos) = try await client.repositories(of: OwnerRef(login: "octo", kind: .user)) else {
            Issue.record("expected fresh"); return
        }
        #expect(repos.count == 2)
        #expect(repos[0] == RepoRef(id: RepoID(rawValue: 1296269), owner: "octo", name: "hello-world", isPrivate: false, isArchived: false, isFork: false))
        #expect(repos[1] == RepoRef(id: RepoID(rawValue: 1296270), owner: "octo", name: "secret-sauce", isPrivate: true, isArchived: true, isFork: true))

        guard case .fresh = try await client.repositories(of: OwnerRef(login: "acme", kind: .organization)) else {
            Issue.record("expected fresh"); return
        }
    }

    @Test func baselineQueryRequestsOpenItems() async throws {
        let stub = StubTransport()
        await stub.enqueue("\(base)/repos/octo/hello-world/issues?state=open&sort=updated&direction=desc&per_page=100", status: 200, body: "[]")
        guard case .fresh(let items) = try await makeClient(stub).items(in: repo, query: .openForBaseline) else {
            Issue.record("expected fresh"); return
        }
        #expect(items.isEmpty)
    }

    @Test func changedQueryRequestsAllStatesSince() async throws {
        let stub = StubTransport()
        let since = Date(timeIntervalSince1970: 1_795_507_200.4) // fractional part must be dropped
        let stamp = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: 1_795_507_200))
        #expect(stamp.hasSuffix("Z"))
        let url = "\(base)/repos/octo/hello-world/issues?state=all&sort=updated&direction=desc&since=\(stamp)&per_page=100"
        await stub.enqueue(url, status: 200, headers: ["ETag": "\"e\""], body: "[]")
        await stub.enqueue(url, status: 304)
        let client = makeClient(stub)
        guard case .fresh = try await client.items(in: repo, query: .changed(since: since)) else { Issue.record("expected fresh"); return }
        // Same Date yields the same URL, so the ETag is reused.
        guard case .notModified = try await client.items(in: repo, query: .changed(since: since)) else { Issue.record("expected notModified"); return }
        #expect(await stub.sent[1].value(forHTTPHeaderField: "If-None-Match") == "\"e\"")
    }

    @Test func issuesMapKindStatusAndBot() async throws {
        let stub = StubTransport()
        await stub.enqueue("\(base)/repos/octo/hello-world/issues?state=open&sort=updated&direction=desc&per_page=100", status: 200, body: try fixtureJSON("issues"))
        guard case .fresh(let items) = try await makeClient(stub).items(in: repo, query: .openForBaseline) else {
            Issue.record("expected fresh"); return
        }
        #expect(items.count == 4)

        let issue = items[0]
        #expect(issue.key == ItemKey(repo: repo.id, number: 7))
        #expect(issue.kind == .issue)
        #expect(issue.status == .open)
        #expect(issue.author == Actor(login: "alice", apiType: "User"))
        #expect(issue.labels == [Label(name: "bug", colorHex: "d73a4a"), Label(name: "help wanted", colorHex: "008672")])
        #expect(issue.assignees == ["bob"])
        #expect(issue.commentCount == 3)
        #expect(issue.url.absoluteString == "https://github.com/octo/hello-world/issues/7")
        #expect(issue.bodyExcerpt == String(repeating: "x", count: 280))
        #expect(issue.createdAt == ISO8601DateFormatter().date(from: "2026-11-20T09:00:00Z"))
        #expect(issue.isDraft == false)
        #expect(issue.requestedReviewers.isEmpty)

        let merged = items[1]
        #expect(merged.kind == .pullRequest)
        #expect(merged.status == .merged)
        #expect(merged.bodyExcerpt == "")

        let bot = items[2]
        #expect(bot.kind == .pullRequest)
        #expect(bot.status == .open)
        #expect(bot.author.isBot)
        #expect(bot.author.botDisplayName == "Dependabot")

        #expect(items[3].status == .closed)
    }

    @Test func pullDetailsKeyedByNumber() async throws {
        let stub = StubTransport()
        await stub.enqueue("\(base)/repos/octo/hello-world/pulls?state=open&per_page=100", status: 200, body: try fixtureJSON("pulls"))
        guard case .fresh(let details) = try await makeClient(stub).openPullDetails(in: repo) else {
            Issue.record("expected fresh"); return
        }
        #expect(details == [
            9: PullDetails(isDraft: true, requestedReviewers: ["bob", "dana"]),
            11: PullDetails(isDraft: false, requestedReviewers: []),
        ])
    }

    @Test func rateLimitReturnsLatest() async throws {
        let stub = StubTransport()
        await stub.enqueue("\(base)/user", status: 200, headers: [
            "X-RateLimit-Limit": "5000", "X-RateLimit-Remaining": "4990", "X-RateLimit-Reset": "1795500000",
        ], body: try fixtureJSON("user"))
        let client = makeClient(stub)
        #expect(await client.rateLimit() == nil)
        _ = try await client.viewer()
        #expect(await client.rateLimit()?.remaining == 4990)
    }
}
