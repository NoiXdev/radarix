import Foundation
import Testing
@testable import RadarixKit

private let base = "https://api.github.com"
private let repo = RepoRef(id: RepoID(rawValue: 1296269), owner: "octo", name: "hello-world", isPrivate: false, isArchived: false, isFork: false)
private let timelineURL = "\(base)/repos/octo/hello-world/issues/7/timeline?per_page=100"
private let since = ISO8601DateFormatter().date(from: "2026-11-24T08:00:00Z")!

private func makeClient(_ stub: StubTransport) -> GitHubClient {
    GitHubClient(token: "tok", transport: stub)
}

private func item(author: String) -> Item { .fixture(number: 7, author: author) }

@Suite struct ActivityProbeTests {
    @Test func otherActivityIgnoresViewerAndOldEntries() async throws {
        let stub = StubTransport()
        // Only an old entry by someone else and a new entry by the viewer.
        await stub.enqueue(timelineURL, status: 200, body: """
        [
          {"event":"commented","actor":{"login":"zed"},"created_at":"2026-11-23T08:00:00Z"},
          {"event":"commented","actor":{"login":"octo"},"created_at":"2026-11-24T09:00:00Z"},
          {"event":"unknown_event","something":{"odd":[1]}}
        ]
        """)
        let result = try await makeClient(stub).hasOtherActivity(on: item(author: "alice"), in: repo, since: since, viewers: ViewerLogins(["octo"]))
        #expect(result == false)
    }

    @Test func otherActivityDetectsCommentsAndReviewsByOthers() async throws {
        let stub = StubTransport()
        await stub.enqueue(timelineURL, status: 200, body: """
        [{"event":"commented","actor":{"login":"zed"},"created_at":"2026-11-24T08:30:00Z"}]
        """)
        #expect(try await makeClient(stub).hasOtherActivity(on: item(author: "alice"), in: repo, since: since, viewers: ViewerLogins(["octo"])))

        let stub2 = StubTransport()
        await stub2.enqueue(timelineURL, status: 200, body: """
        [{"event":"reviewed","user":{"login":"bob"},"submitted_at":"2026-11-24T09:30:00Z"}]
        """)
        #expect(try await makeClient(stub2).hasOtherActivity(on: item(author: "alice"), in: repo, since: since, viewers: ViewerLogins(["octo"])))
    }

    @Test func otherAccountActivityIsNotOther() async throws {
        let stub = StubTransport()
        await stub.enqueue(timelineURL, status: 200, body: """
        [{"event":"commented","actor":{"login":"work"},"created_at":"2026-11-24T09:00:00Z"}]
        """)
        let result = try await makeClient(stub).hasOtherActivity(
            on: item(author: "alice"), in: repo, since: since, viewers: ViewerLogins(["me", "work"]))
        #expect(result == false)
    }

    @Test func entryExactlyAtSinceIsIgnored() async throws {
        let stub = StubTransport()
        await stub.enqueue(timelineURL, status: 200, body: """
        [{"event":"commented","actor":{"login":"zed"},"created_at":"2026-11-24T08:00:00Z"}]
        """)
        #expect(try await makeClient(stub).hasOtherActivity(on: item(author: "alice"), in: repo, since: since, viewers: ViewerLogins(["octo"])) == false)
    }

    @Test func committedEventsAreOwnWhenViewerAuthoredTheItem() async throws {
        let body = """
        [{"event":"committed","author":{"date":"2026-11-24T09:45:00Z"},"committer":{"date":"2026-11-24T09:45:00Z"}}]
        """
        let own = StubTransport()
        await own.enqueue(timelineURL, status: 200, body: body)
        #expect(try await makeClient(own).hasOtherActivity(on: item(author: "octo"), in: repo, since: since, viewers: ViewerLogins(["octo"])) == false)

        let foreign = StubTransport()
        await foreign.enqueue(timelineURL, status: 200, body: body)
        #expect(try await makeClient(foreign).hasOtherActivity(on: item(author: "alice"), in: repo, since: since, viewers: ViewerLogins(["octo"])))
    }

    @Test func fixtureTimelineHasOtherActivity() async throws {
        let stub = StubTransport()
        await stub.enqueue(timelineURL, status: 200, body: try fixtureJSON("timeline"))
        #expect(try await makeClient(stub).hasOtherActivity(on: item(author: "alice"), in: repo, since: since, viewers: ViewerLogins(["octo"])))
    }

    @Test func otherActivityReadsLastPage() async throws {
        let stub = StubTransport()
        let page3 = "\(base)/repos/octo/hello-world/issues/7/timeline?per_page=100&page=3"
        await stub.enqueue(timelineURL, status: 200, headers: [
            "Link": "<\(base)/repos/octo/hello-world/issues/7/timeline?per_page=100&page=2>; rel=\"next\", <\(page3)>; rel=\"last\"",
        ], body: """
        [{"event":"commented","actor":{"login":"zed"},"created_at":"2026-11-24T09:00:00Z"}]
        """)
        await stub.enqueue(page3, status: 200, body: """
        [{"event":"commented","actor":{"login":"octo"},"created_at":"2026-11-24T09:00:00Z"}]
        """)
        // Page 1 would say true; only the last page (viewer's own comment) counts.
        let result = try await makeClient(stub).hasOtherActivity(on: item(author: "alice"), in: repo, since: since, viewers: ViewerLogins(["octo"]))
        #expect(result == false)
        #expect(await stub.sent.count == 2)
        #expect(await stub.sent[1].url?.absoluteString == page3)
    }
}
