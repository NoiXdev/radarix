import Foundation
import Testing
@testable import RadarixKit

private let graphQLURL = "https://api.github.com/graphql"
private let repo = RepoRef(id: RepoID(rawValue: 1296269), owner: "octo", name: "hello-world", isPrivate: false, isArchived: false, isFork: false)
private let since = Date(timeIntervalSince1970: 1_793_001_600) // 2026-10-26T08:00:00Z
private let inside = "2026-11-01T10:00:00Z"
private let outside = "2026-10-01T10:00:00Z"

private func makeClient(_ stub: StubTransport) -> GitHubClient {
    GitHubClient(token: "tok", transport: stub)
}

private func page(_ dates: [String], hasNext: Bool = false, cursor: String? = nil, key: String = "edges") -> String {
    let entries = dates.map { key == "edges" ? #"{"starredAt":"\#($0)"}"# : #"{"createdAt":"\#($0)"}"# }
    let end = cursor.map { #""\#($0)""# } ?? "null"
    return #"{"pageInfo":{"hasNextPage":\#(hasNext),"endCursor":\#(end)},"\#(key)":[\#(entries.joined(separator: ","))]}"#
}

private func firstResponse(
    stargazers: String = page([]), forks: String = page([], key: "nodes"),
    spdxId: String? = "MIT", licenseName: String = "MIT License", stargazerCount: Int = 1420
) -> String {
    let spdx = spdxId.map { #""\#($0)""# } ?? "null"
    return """
    {"data":{"repository":{
      "description":"A repo","primaryLanguage":{"name":"Swift"},
      "licenseInfo":{"spdxId":\(spdx),"name":"\(licenseName)"},
      "repositoryTopics":{"nodes":[{"topic":{"name":"swift"}},{"topic":{"name":"macos"}}]},
      "stargazerCount":\(stargazerCount),"forkCount":87,"watchers":{"totalCount":31},
      "issues":{"totalCount":9},"pullRequests":{"totalCount":3},
      "latestRelease":{"name":"Two","tagName":"v2.0.0","publishedAt":"2026-11-02T09:00:00Z"},
      "stargazers":\(stargazers),"forks":\(forks)},
      "openedIssues":{"issueCount":4},"openedPulls":{"issueCount":6},"mergedPulls":{"issueCount":5}}}
    """
}

private func followUp(stargazers: String? = nil, forks: String? = nil) -> String {
    let field = stargazers.map { #""stargazers":\#($0)"# } ?? #""forks":\#(forks ?? "")"#
    return #"{"data":{"repository":{\#(field)}}}"#
}

private func variables(of request: URLRequest) throws -> [String: String] {
    let body = try #require(request.httpBody)
    let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
    return try #require(json["variables"] as? [String: String])
}

@Suite struct RepoInsightsTests {
    @Test func insightsSendsOneQuery() async throws {
        let stub = StubTransport()
        await stub.enqueue(graphQLURL, status: 200, body: firstResponse())
        _ = try await makeClient(stub).insights(for: repo, since: since)
        let sent = await stub.sent
        #expect(sent.count == 1)
        let request = try #require(sent.first)
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
        let vars = try variables(of: request)
        #expect(vars["owner"] == "octo")
        #expect(vars["name"] == "hello-world")
        #expect(vars["issues"] == "repo:octo/hello-world is:issue created:>=2026-10-26")
        #expect(vars["pulls"] == "repo:octo/hello-world is:pr created:>=2026-10-26")
        #expect(vars["merged"] == "repo:octo/hello-world is:pr is:merged merged:>=2026-10-26")
        let body = try #require(request.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["query"] as? String == RepoInsights.query)
    }

    @Test func insightsDecodesCounts() async throws {
        let stub = StubTransport()
        await stub.enqueue(graphQLURL, status: 200, body: firstResponse())
        let insights = try await makeClient(stub).insights(for: repo, since: since)
        #expect(insights.description == "A repo")
        #expect(insights.language == "Swift")
        #expect(insights.license == "MIT")
        #expect(insights.topics == ["swift", "macos"])
        #expect(insights.stars == 1420)
        #expect(insights.forks == 87)
        #expect(insights.watchers == 31)
        #expect(insights.openIssues == 9)
        #expect(insights.openPulls == 3)
        #expect(insights.latestRelease == Release(name: "Two", tag: "v2.0.0", publishedAt: Date(timeIntervalSince1970: 1_793_610_000)))
        #expect(insights.period[.openedIssues] == PeriodCount(value: 4, atLeast: false))
        #expect(insights.period[.openedPulls] == PeriodCount(value: 6, atLeast: false))
        #expect(insights.period[.mergedPulls] == PeriodCount(value: 5, atLeast: false))
    }

    @Test func starsCountedWithinPeriod() async throws {
        let stub = StubTransport()
        let stars = page([inside, inside, inside, outside, outside], hasNext: true, cursor: "c1")
        await stub.enqueue(graphQLURL, status: 200, body: firstResponse(stargazers: stars))
        let insights = try await makeClient(stub).insights(for: repo, since: since)
        #expect(insights.period[.stars] == PeriodCount(value: 3, atLeast: false))
        #expect(await stub.sent.count == 1)
    }

    @Test func hiddenStargazerListLeavesStarsOut() async throws {
        let stub = StubTransport()
        await stub.enqueue(graphQLURL, status: 200, body: firstResponse(stargazers: page([]), stargazerCount: 1420))
        let insights = try await makeClient(stub).insights(for: repo, since: since)
        #expect(insights.period[.stars] == nil)
        #expect(insights.period[.openedIssues] == PeriodCount(value: 4, atLeast: false))
    }

    @Test func repositoryWithoutStarsCountsZero() async throws {
        let stub = StubTransport()
        await stub.enqueue(graphQLURL, status: 200, body: firstResponse(stargazers: page([]), stargazerCount: 0))
        let insights = try await makeClient(stub).insights(for: repo, since: since)
        #expect(insights.period[.stars] == PeriodCount(value: 0, atLeast: false))
    }

    @Test func starsFollowNextPage() async throws {
        let stub = StubTransport()
        let first = page(Array(repeating: inside, count: 100), hasNext: true, cursor: "c1")
        let second = page(Array(repeating: inside, count: 20) + Array(repeating: outside, count: 5))
        await stub.enqueue(graphQLURL, status: 200, body: firstResponse(stargazers: first))
        await stub.enqueue(graphQLURL, status: 200, body: followUp(stargazers: second))
        let insights = try await makeClient(stub).insights(for: repo, since: since)
        #expect(insights.period[.stars] == PeriodCount(value: 120, atLeast: false))
        let sent = await stub.sent
        #expect(sent.count == 2)
        #expect(try variables(of: sent[1])["after"] == "c1")
    }

    @Test func starsCappedAtFivePages() async throws {
        let stub = StubTransport()
        let full = { (cursor: String) in page(Array(repeating: inside, count: 100), hasNext: true, cursor: cursor) }
        await stub.enqueue(graphQLURL, status: 200, body: firstResponse(stargazers: full("c1")))
        for cursor in ["c2", "c3", "c4", "c5"] {
            await stub.enqueue(graphQLURL, status: 200, body: followUp(stargazers: full(cursor)))
        }
        let insights = try await makeClient(stub).insights(for: repo, since: since)
        #expect(insights.period[.stars] == PeriodCount(value: 500, atLeast: true))
        #expect(await stub.sent.count == 5)
    }

    @Test func missingCursorOnFullPageIsAtLeast() async throws {
        let stub = StubTransport()
        let stars = page([inside, inside, inside], hasNext: true, cursor: nil)
        await stub.enqueue(graphQLURL, status: 200, body: firstResponse(stargazers: stars))
        let insights = try await makeClient(stub).insights(for: repo, since: since)
        #expect(insights.period[.stars] == PeriodCount(value: 3, atLeast: true))
        #expect(await stub.sent.count == 1)
    }

    @Test func searchDayIsUTCAndBoundIsInclusive() async throws {
        let stub = StubTransport()
        let late = Date(timeIntervalSince1970: 1_793_057_400) // 2026-10-26T23:30:00Z
        let stars = page(["2026-10-26T23:30:00Z", "2026-10-26T23:29:59Z"])
        await stub.enqueue(graphQLURL, status: 200, body: firstResponse(stargazers: stars))
        let insights = try await makeClient(stub).insights(for: repo, since: late)
        let request = try #require(await stub.sent.first)
        #expect(try variables(of: request)["issues"] == "repo:octo/hello-world is:issue created:>=2026-10-26")
        #expect(insights.period[.stars] == PeriodCount(value: 1, atLeast: false))
    }

    @Test func forksCountedWithinPeriod() async throws {
        let stub = StubTransport()
        let first = page(Array(repeating: inside, count: 100), hasNext: true, cursor: "f1", key: "nodes")
        let second = page(Array(repeating: inside, count: 20) + Array(repeating: outside, count: 5), key: "nodes")
        await stub.enqueue(graphQLURL, status: 200, body: firstResponse(forks: first))
        await stub.enqueue(graphQLURL, status: 200, body: followUp(forks: second))
        let insights = try await makeClient(stub).insights(for: repo, since: since)
        #expect(insights.period[.forks] == PeriodCount(value: 120, atLeast: false))
        let sent = await stub.sent
        #expect(sent.count == 2)
        #expect(try variables(of: sent[1])["after"] == "f1")
    }

    @Test func graphQLNotFoundMaps() async throws {
        let stub = StubTransport()
        await stub.enqueue(
            graphQLURL, status: 200,
            body: #"{"data":{"repository":null},"errors":[{"type":"NOT_FOUND","message":"x"}]}"#)
        await #expect(throws: GitHubError.notFound) {
            _ = try await makeClient(stub).insights(for: repo, since: since)
        }
    }

    @Test func graphQLForbiddenMaps() async throws {
        let stub = StubTransport()
        await stub.enqueue(
            graphQLURL, status: 200,
            body: #"{"data":null,"errors":[{"type":"FORBIDDEN","message":"no access"}]}"#)
        await #expect(throws: GitHubError.forbidden("no access")) {
            _ = try await makeClient(stub).insights(for: repo, since: since)
        }
    }

    @Test func graphQLRateLimitedMaps() async throws {
        let stub = StubTransport()
        await stub.enqueue(
            graphQLURL, status: 200, headers: ["X-RateLimit-Reset": "1900000000"],
            body: #"{"data":null,"errors":[{"type":"RATE_LIMITED","message":"slow down"}]}"#)
        await #expect(throws: GitHubError.rateLimited(resetAt: Date(timeIntervalSince1970: 1_900_000_000))) {
            _ = try await makeClient(stub).insights(for: repo, since: since)
        }
    }

    @Test func graphQLOtherErrorIsDecoding() async throws {
        let stub = StubTransport()
        await stub.enqueue(graphQLURL, status: 200, body: #"{"data":null,"errors":[{"message":"boom"}]}"#)
        await #expect(throws: GitHubError.decoding("boom")) {
            _ = try await makeClient(stub).insights(for: repo, since: since)
        }
    }

    @Test func graphQLNullDataIsDecoding() async throws {
        let stub = StubTransport()
        await stub.enqueue(graphQLURL, status: 200, body: #"{"data":null}"#)
        do {
            _ = try await makeClient(stub).insights(for: repo, since: since)
            Issue.record("expected a throw")
        } catch let error as GitHubError {
            guard case .decoding = error else {
                Issue.record("expected .decoding, got \(error)")
                return
            }
        }
    }

    @Test func graphQLLeavesRateLimit() async throws {
        let stub = StubTransport()
        let rest = "https://api.github.com/user"
        await stub.enqueue(
            rest, status: 200,
            headers: ["X-RateLimit-Limit": "5000", "X-RateLimit-Remaining": "4000", "X-RateLimit-Reset": "1795500000"],
            body: #"{"id":1,"login":"octo"}"#)
        await stub.enqueue(
            graphQLURL, status: 200,
            headers: ["X-RateLimit-Limit": "5000", "X-RateLimit-Remaining": "10", "X-RateLimit-Reset": "1795500000"],
            body: firstResponse())
        let client = makeClient(stub)
        _ = try await client.viewer()
        _ = try await client.insights(for: repo, since: since)
        #expect(await client.latestRateLimit?.remaining == 4000)
    }

    @Test func licenseNoAssertionUsesName() async throws {
        let stub = StubTransport()
        await stub.enqueue(graphQLURL, status: 200, body: firstResponse(spdxId: "NOASSERTION", licenseName: "Other"))
        let insights = try await makeClient(stub).insights(for: repo, since: since)
        #expect(insights.license == "Other")
    }
}
