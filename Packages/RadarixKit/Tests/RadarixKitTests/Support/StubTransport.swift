import Foundation
@testable import RadarixKit

/// Canned `HTTPTransport` for tests.
///
/// Responses are queued per full request URL (`absoluteString`, query included)
/// and served first-in-first-out. A queued response is either a stubbed reply or
/// a thrown error. Every sent request is recorded in `sent`. A request with no
/// queued response fails the test run via a thrown `StubError.unexpectedRequest`.
actor StubTransport: HTTPTransport {
    enum Canned: Sendable {
        case reply(status: Int, headers: [String: String], body: Data)
        case failure(URLError)
    }

    enum StubError: Error { case unexpectedRequest(String) }

    private var queues: [String: [Canned]] = [:]
    private(set) var sent: [URLRequest] = []

    func enqueue(_ url: String, status: Int, headers: [String: String] = [:], body: String = "") {
        queues[url, default: []].append(.reply(status: status, headers: headers, body: Data(body.utf8)))
    }

    func enqueue(_ url: String, failure: URLError) {
        queues[url, default: []].append(.failure(failure))
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        sent.append(request)
        let key = request.url?.absoluteString ?? ""
        guard var queue = queues[key], !queue.isEmpty else {
            throw StubError.unexpectedRequest(key)
        }
        let next = queue.removeFirst()
        queues[key] = queue
        switch next {
        case .failure(let error):
            throw error
        case .reply(let status, let headers, let body):
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            return (body, response)
        }
    }
}
