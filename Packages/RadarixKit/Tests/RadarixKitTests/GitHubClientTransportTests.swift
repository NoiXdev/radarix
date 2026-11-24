import Foundation
import Testing
@testable import RadarixKit

private struct Thing: Decodable, Equatable, Sendable {
    let id: Int
    let createdAt: Date?
}

private let base = "https://api.github.com"

private func makeClient(_ stub: StubTransport) -> GitHubClient {
    GitHubClient(token: "SECRET-TOKEN-123", transport: stub)
}

@Suite struct GitHubClientTransportTests {
    @Test func sendsAuthAndApiHeaders() async throws {
        let stub = StubTransport()
        await stub.enqueue("\(base)/user", status: 200, body: #"{"id":1}"#)
        let _: Thing = try await makeClient(stub).get("/user", query: [])
        let request = try #require(await stub.sent.first)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer SECRET-TOKEN-123")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/vnd.github+json")
        #expect(request.value(forHTTPHeaderField: "X-GitHub-Api-Version") == "2022-11-28")
        #expect(request.httpMethod == "GET")
    }

    @Test func decodesSnakeCaseAndIso8601() async throws {
        let stub = StubTransport()
        await stub.enqueue("\(base)/t", status: 200, body: #"{"id":7,"created_at":"2026-11-24T10:00:00Z"}"#)
        let thing: Thing = try await makeClient(stub).get("/t", query: [])
        #expect(thing.id == 7)
        #expect(thing.createdAt == ISO8601DateFormatter().date(from: "2026-11-24T10:00:00Z"))
    }

    @Test func decodingFailureMapsToDecodingError() async throws {
        let stub = StubTransport()
        await stub.enqueue("\(base)/t", status: 200, body: #"{"nope":1}"#)
        await #expect {
            let _: Thing = try await makeClient(stub).get("/t", query: [])
        } throws: { error in
            if case GitHubError.decoding = error { return true }
            return false
        }
    }

    @Test func reusesETagAndReturnsNotModifiedOn304() async throws {
        let stub = StubTransport()
        let url = "\(base)/repos/a/b/issues?state=all"
        await stub.enqueue(url, status: 200, headers: ["ETag": "\"abc\""], body: #"{"id":1}"#)
        await stub.enqueue(url, status: 304)
        let client = makeClient(stub)
        let query = [URLQueryItem(name: "state", value: "all")]

        let first: Fetch<Thing> = try await client.getConditional("/repos/a/b/issues", query: query)
        guard case .fresh(let value) = first else { Issue.record("expected fresh"); return }
        #expect(value.id == 1)

        let second: Fetch<Thing> = try await client.getConditional("/repos/a/b/issues", query: query)
        guard case .notModified = second else { Issue.record("expected notModified"); return }

        let sent = await stub.sent
        #expect(sent.count == 2)
        #expect(sent[0].value(forHTTPHeaderField: "If-None-Match") == nil)
        #expect(sent[1].value(forHTTPHeaderField: "If-None-Match") == "\"abc\"")
    }

    @Test func unconditionalGetNeverSendsIfNoneMatch() async throws {
        let stub = StubTransport()
        await stub.enqueue("\(base)/t", status: 200, headers: ["ETag": "\"x\""], body: #"{"id":1}"#)
        await stub.enqueue("\(base)/t", status: 200, body: #"{"id":1}"#)
        let client = makeClient(stub)
        let _: Thing = try await client.get("/t", query: [])
        let _: Thing = try await client.get("/t", query: [])
        #expect(await stub.sent[1].value(forHTTPHeaderField: "If-None-Match") == nil)
    }

    @Test func parsesRateLimitHeaders() async throws {
        let stub = StubTransport()
        await stub.enqueue("\(base)/t", status: 200, headers: [
            "X-RateLimit-Limit": "5000", "X-RateLimit-Remaining": "4999", "X-RateLimit-Reset": "1795500000",
        ], body: #"{"id":1}"#)
        let client = makeClient(stub)
        #expect(await client.latestRateLimit == nil)
        let _: Thing = try await client.get("/t", query: [])
        #expect(await client.latestRateLimit == RateLimit(limit: 5000, remaining: 4999, resetAt: Date(timeIntervalSince1970: 1_795_500_000)))
    }

    @Test func rateLimitIsUpdatedFrom304AndErrorResponses() async throws {
        let stub = StubTransport()
        await stub.enqueue("\(base)/t", status: 304, headers: [
            "X-RateLimit-Limit": "5000", "X-RateLimit-Remaining": "4000", "X-RateLimit-Reset": "1795500000",
        ])
        await stub.enqueue("\(base)/u", status: 404, headers: [
            "X-RateLimit-Limit": "5000", "X-RateLimit-Remaining": "3999", "X-RateLimit-Reset": "1795500000",
        ])
        let client = makeClient(stub)
        let _: Fetch<Thing> = try await client.getConditional("/t", query: [])
        #expect(await client.latestRateLimit?.remaining == 4000)
        _ = try? await client.get("/u", query: []) as Thing
        #expect(await client.latestRateLimit?.remaining == 3999)
    }

    private func expectError(_ expected: GitHubError, status: Int, headers: [String: String] = [:], body: String = "") async throws {
        let stub = StubTransport()
        await stub.enqueue("\(base)/t", status: status, headers: headers, body: body)
        do {
            let _: Thing = try await makeClient(stub).get("/t", query: [])
            Issue.record("expected \(expected)")
        } catch let error as GitHubError {
            #expect(error == expected)
        }
    }

    @Test func mapsStatusCodes() async throws {
        try await expectError(.unauthorized, status: 401)
        try await expectError(.notFound, status: 404)
        try await expectError(.http(500), status: 500)
        try await expectError(.forbidden("Resource not accessible"), status: 403, body: #"{"message":"Resource not accessible"}"#)
        try await expectError(.forbidden(nil), status: 403, body: "not json")
        try await expectError(
            .rateLimited(resetAt: Date(timeIntervalSince1970: 1_795_500_000)),
            status: 403,
            headers: ["X-RateLimit-Remaining": "0", "X-RateLimit-Reset": "1795500000"]
        )
        try await expectError(
            .rateLimited(resetAt: Date(timeIntervalSince1970: 1_795_500_000)),
            status: 429,
            headers: ["X-RateLimit-Reset": "1795500000"]
        )
    }

    @Test func rateLimited429PrefersRetryAfterThenFallsBackToNowPlus60() async throws {
        let stub = StubTransport()
        await stub.enqueue("\(base)/a", status: 429, headers: ["Retry-After": "30", "X-RateLimit-Reset": "1795500000"])
        await stub.enqueue("\(base)/b", status: 429)
        let client = makeClient(stub)

        var before = Date()
        do { let _: Thing = try await client.get("/a", query: []); Issue.record("expected throw") } catch GitHubError.rateLimited(let resetAt) {
            #expect(resetAt >= before.addingTimeInterval(30) && resetAt <= Date().addingTimeInterval(30))
        }
        before = Date()
        do { let _: Thing = try await client.get("/b", query: []); Issue.record("expected throw") } catch GitHubError.rateLimited(let resetAt) {
            #expect(resetAt >= before.addingTimeInterval(60) && resetAt <= Date().addingTimeInterval(60))
        }
    }

    @Test func urlErrorMapsToNetwork() async throws {
        let stub = StubTransport()
        await stub.enqueue("\(base)/t", failure: URLError(.notConnectedToInternet))
        do {
            let _: Thing = try await makeClient(stub).get("/t", query: [])
            Issue.record("expected error")
        } catch let error as GitHubError {
            guard case .network = error else { Issue.record("expected network, got \(error)"); return }
        }
    }

    @Test func errorsNeverContainTheToken() async throws {
        let stub = StubTransport()
        await stub.enqueue("\(base)/t", failure: URLError(.notConnectedToInternet))
        do {
            let _: Thing = try await makeClient(stub).get("/t", query: [])
            Issue.record("expected throw")
        } catch {
            #expect(!String(describing: error).contains("SECRET-TOKEN-123"))
        }
    }

    @Test func followsLinkNextAcrossPages() async throws {
        let stub = StubTransport()
        let page2 = "\(base)/repos/a/b/issues?state=all&per_page=100&page=2"
        await stub.enqueue("\(base)/repos/a/b/issues?state=all&per_page=100", status: 200,
                           headers: ["Link": "<\(page2)>; rel=\"next\", <\(base)/x?page=2>; rel=\"last\""],
                           body: #"[{"id":1},{"id":2}]"#)
        await stub.enqueue(page2, status: 200, body: #"[{"id":3}]"#)
        let result: [Thing] = try await makeClient(stub).getAllPages("/repos/a/b/issues", query: [URLQueryItem(name: "state", value: "all")])
        #expect(result.map(\.id) == [1, 2, 3])
        #expect(await stub.sent.count == 2)
    }

    @Test func conditionalPagedReturnsNotModifiedWhenFirstPageIs304() async throws {
        let stub = StubTransport()
        let page1 = "\(base)/items?per_page=100"
        let page2 = "\(base)/items?per_page=100&page=2"
        await stub.enqueue(page1, status: 200, headers: ["ETag": "\"p1\"", "Link": "<\(page2)>; rel=\"next\""], body: #"[{"id":1}]"#)
        await stub.enqueue(page2, status: 200, headers: ["ETag": "\"p2\""], body: #"[{"id":2}]"#)
        await stub.enqueue(page1, status: 304)
        let client = makeClient(stub)

        let first: Fetch<[Thing]> = try await client.getAllPagesConditional("/items", query: [])
        guard case .fresh(let items) = first else { Issue.record("expected fresh"); return }
        #expect(items.map(\.id) == [1, 2])

        let second: Fetch<[Thing]> = try await client.getAllPagesConditional("/items", query: [])
        guard case .notModified = second else { Issue.record("expected notModified"); return }

        let sent = await stub.sent
        #expect(sent.count == 3)
        #expect(sent[1].value(forHTTPHeaderField: "If-None-Match") == nil) // page 2 is never conditional
        #expect(sent[2].value(forHTTPHeaderField: "If-None-Match") == "\"p1\"")
    }

    @Test func failedLaterPageStoresNoETag() async throws {
        for status in [500, 429] {
            let stub = StubTransport()
            let page1 = "\(base)/items?per_page=100"
            let page2 = "\(base)/items?per_page=100&page=2"
            await stub.enqueue(page1, status: 200, headers: ["ETag": "\"p1\"", "Link": "<\(page2)>; rel=\"next\""], body: #"[{"id":1}]"#)
            await stub.enqueue(page2, status: status)
            await stub.enqueue(page1, status: 200, body: #"[{"id":1}]"#)
            let client = makeClient(stub)

            await #expect(throws: GitHubError.self) {
                let _: Fetch<[Thing]> = try await client.getAllPagesConditional("/items", query: [])
            }
            let _: Fetch<[Thing]> = try await client.getAllPagesConditional("/items", query: [])
            #expect(await stub.sent[2].value(forHTTPHeaderField: "If-None-Match") == nil, "status \(status)")
        }
    }

    @Test func undecodableResponseStoresNoETag() async throws {
        let stub = StubTransport()
        await stub.enqueue("\(base)/t", status: 200, headers: ["ETag": "\"bad\""], body: "not json")
        await stub.enqueue("\(base)/t", status: 200, body: #"{"id":1}"#)
        await stub.enqueue("\(base)/items?per_page=100", status: 200, headers: ["ETag": "\"bad\""], body: "not json")
        await stub.enqueue("\(base)/items?per_page=100", status: 200, body: "[]")
        let client = makeClient(stub)

        await #expect(throws: GitHubError.self) {
            let _: Fetch<Thing> = try await client.getConditional("/t", query: [])
        }
        let _: Fetch<Thing> = try await client.getConditional("/t", query: [])
        await #expect(throws: GitHubError.self) {
            let _: Fetch<[Thing]> = try await client.getAllPagesConditional("/items", query: [])
        }
        let _: Fetch<[Thing]> = try await client.getAllPagesConditional("/items", query: [])

        let sent = await stub.sent
        #expect(sent[1].value(forHTTPHeaderField: "If-None-Match") == nil)
        #expect(sent[3].value(forHTTPHeaderField: "If-None-Match") == nil)
    }

    @Test func cancelledRequestThrowsCancellationError() async throws {
        let stub = StubTransport()
        await stub.enqueue("\(base)/t", failure: URLError(.cancelled))
        await #expect(throws: CancellationError.self) {
            let _: Thing = try await makeClient(stub).get("/t", query: [])
        }
    }

    @Test func nonConditionalPagedFirstPageNeverSendsIfNoneMatch() async throws {
        let stub = StubTransport()
        let page1 = "\(base)/items?per_page=100"
        await stub.enqueue(page1, status: 200, headers: ["ETag": "\"p1\""], body: #"[{"id":1}]"#)
        await stub.enqueue(page1, status: 200, body: #"[{"id":1}]"#)
        let client = makeClient(stub)
        let _: [Thing] = try await client.getAllPages("/items", query: [])
        let _: [Thing] = try await client.getAllPages("/items", query: [])
        #expect(await stub.sent[1].value(forHTTPHeaderField: "If-None-Match") == nil)
    }

    @Test func secondaryRateLimit403UsesRetryAfter() async throws {
        let stub = StubTransport()
        await stub.enqueue("\(base)/t", status: 403, headers: ["Retry-After": "45", "X-RateLimit-Remaining": "100"])
        let before = Date()
        do {
            let _: Thing = try await makeClient(stub).get("/t", query: [])
            Issue.record("expected throw")
        } catch GitHubError.rateLimited(let resetAt) {
            #expect(resetAt >= before.addingTimeInterval(45) && resetAt <= Date().addingTimeInterval(45))
        }
    }

    @Test func nonConditionalPagedThrowsOn304() async throws {
        let stub = StubTransport()
        await stub.enqueue("\(base)/items?per_page=100", status: 304)
        do {
            let _: [Thing] = try await makeClient(stub).getAllPages("/items", query: [])
            Issue.record("expected throw")
        } catch let error as GitHubError {
            #expect(error == .http(304))
        }
    }
}
