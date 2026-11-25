import Foundation

public enum Fetch<Value: Sendable>: Sendable {
    case notModified
    case fresh(Value)
}

/// A GraphQL reply: `data` and/or `errors`.
private struct GraphQLEnvelope<T: Decodable>: Decodable {
    struct Failure: Decodable { let type: String?; let message: String }
    let errors: [Failure]?
    /// The decoded `data`, or why it did not decode. A reply with `errors` may carry partial `data`
    /// (a null `repository`), so a decode failure only matters when there are no `errors`.
    let data: Result<T?, any Error>

    private enum CodingKeys: String, CodingKey { case data, errors }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        errors = try container.decodeIfPresent([Failure].self, forKey: .errors)
        data = Result { try container.decodeIfPresent(T.self, forKey: .data) }
    }
}

/// Minimal GitHub REST client: auth headers, ETag cache, rate-limit tracking, pagination.
/// Endpoint methods live in extensions elsewhere.
public actor GitHubClient {
    private let token: String
    private let transport: HTTPTransport
    private let baseURL: URL
    private var etags: [String: String] = [:]
    public private(set) var latestRateLimit: RateLimit?

    public init(token: String, transport: HTTPTransport = URLSessionTransport(), baseURL: URL = URL(string: "https://api.github.com")!) {
        self.token = token
        self.transport = transport
        self.baseURL = baseURL
    }

    // MARK: Single requests

    public func get<T: Decodable>(
        _ path: String, query: [URLQueryItem], accept: String = "application/vnd.github+json"
    ) async throws -> T {
        let url = try makeURL(path, query: query)
        let (data, response) = try await perform(url, conditional: false, accept: accept)
        guard let data else { throw GitHubError.http(response.statusCode) }
        return try decode(T.self, from: data)
    }

    /// A write: sends `method` with a JSON `body` and decodes the answer. Same headers, error
    /// mapping and rate-limit tracking as a read; never conditional, stores no ETag.
    public func send<T: Decodable>(_ method: String, _ path: String, json body: Data) async throws -> T {
        let url = try makeURL(path, query: [])
        let (data, response) = try await perform(url, conditional: false, method: method, body: body)
        guard let data else { throw GitHubError.http(response.statusCode) }
        return try decode(T.self, from: data)
    }

    /// Runs a GraphQL query. Errors in the reply map to `GitHubError`; HTTP errors map as for REST.
    /// GraphQL answers carry the separate GraphQL budget in `X-RateLimit-*`, so they never touch `latestRateLimit`.
    public func graphQL<T: Decodable>(_ query: String, variables: [String: String]) async throws -> T {
        let url = try makeURL("/graphql", query: [])
        let body = try JSONSerialization.data(withJSONObject: ["query": query, "variables": variables])
        let (data, response) = try await perform(url, conditional: false, method: "POST", body: body, tracksRateLimit: false)
        guard let data else { throw GitHubError.http(response.statusCode) }
        let envelope = try decode(GraphQLEnvelope<T>.self, from: data)
        if let failure = envelope.errors?.first {
            switch failure.type {
            case "NOT_FOUND": throw GitHubError.notFound
            case "FORBIDDEN": throw GitHubError.forbidden(failure.message)
            case "RATE_LIMITED": throw GitHubError.rateLimited(resetAt: resetDate(response))
            default: throw GitHubError.decoding(failure.message)
            }
        }
        do {
            guard let value = try envelope.data.get() else { throw GitHubError.decoding("GraphQL reply has no data") }
            return value
        } catch let error as GitHubError {
            throw error
        } catch {
            throw GitHubError.decoding(String(describing: error))
        }
    }

    public func getConditional<T: Decodable>(_ path: String, query: [URLQueryItem]) async throws -> Fetch<T> {
        let url = try makeURL(path, query: query)
        let (data, response) = try await perform(url, conditional: true)
        guard let data, response.statusCode != 304 else { return .notModified }
        let value = try decode(T.self, from: data)
        rememberETag(of: response, for: url)
        return .fresh(value)
    }

    // MARK: Paged requests

    public func getAllPages<T: Decodable>(_ path: String, query: [URLQueryItem]) async throws -> [T] {
        let first = try makeURL(path, query: pagedQuery(query))
        return try await collectPages(from: first, conditional: false)
    }

    public func getAllPagesConditional<T: Decodable>(_ path: String, query: [URLQueryItem]) async throws -> Fetch<[T]> {
        let first = try makeURL(path, query: pagedQuery(query))
        guard let items: [T] = try await collectPagesOrNil(from: first, conditional: true) else { return .notModified }
        return .fresh(items)
    }

    /// Elements of the last page of a paged resource: fetches page 1, then the `rel="last"` URL when present.
    public func getLastPage<T: Decodable>(_ path: String, query: [URLQueryItem]) async throws -> [T] {
        let first = try makeURL(path, query: pagedQuery(query))
        let (data, response) = try await perform(first, conditional: false)
        guard let data else { throw GitHubError.http(response.statusCode) }
        guard let last = link(rel: "last", in: response), last != first else { return try decode([T].self, from: data) }
        let (lastData, lastResponse) = try await perform(last, conditional: false)
        guard let lastData else { throw GitHubError.http(lastResponse.statusCode) }
        return try decode([T].self, from: lastData)
    }

    private func collectPages<T: Decodable>(from first: URL, conditional: Bool) async throws -> [T] {
        try await collectPagesOrNil(from: first, conditional: conditional) ?? []
    }

    /// Returns nil when the (conditional) first page answered 304.
    /// The first page's ETag is committed only once every page is fetched and decoded,
    /// so a failed fetch can never be answered with 304 next time.
    private func collectPagesOrNil<T: Decodable>(from first: URL, conditional: Bool) async throws -> [T]? {
        var result: [T] = []
        var next: URL? = first
        var firstResponse: HTTPURLResponse?
        while let url = next {
            let isFirst = firstResponse == nil
            let (data, response) = try await perform(url, conditional: conditional && isFirst)
            guard let data, response.statusCode != 304 else {
                if conditional && isFirst { return nil }
                throw GitHubError.http(304)
            }
            result += try decode([T].self, from: data)
            next = nextLink(in: response)
            if isFirst { firstResponse = response }
        }
        if conditional, let firstResponse { rememberETag(of: firstResponse, for: first) }
        return result
    }

    private func rememberETag(of response: HTTPURLResponse, for url: URL) {
        guard response.statusCode == 200, let etag = response.value(forHTTPHeaderField: "ETag") else { return }
        etags[url.absoluteString] = etag
    }

    // MARK: Conditional state

    /// Drops every cached ETag for URLs under `/repos/{owner}/{name}/` (case-insensitive),
    /// so the next conditional request for that repo answers with a full response.
    public func forgetConditionalState(for repo: RepoRef) {
        let basePath = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)?.path ?? ""
        let prefix = (basePath.hasSuffix("/") ? String(basePath.dropLast()) : basePath)
            + "/repos/\(repo.owner)/\(repo.name)/"
        let lowered = prefix.lowercased()
        etags = etags.filter { key, _ in
            guard let path = URLComponents(string: key)?.path else { return true }
            return !path.lowercased().hasPrefix(lowered)
        }
    }

    // MARK: Plumbing

    private func pagedQuery(_ query: [URLQueryItem]) -> [URLQueryItem] {
        query.contains { $0.name == "per_page" } ? query : query + [URLQueryItem(name: "per_page", value: "100")]
    }

    private func makeURL(_ path: String, query: [URLQueryItem]) throws -> URL {
        guard var components = URLComponents(url: baseURL.appending(path: path), resolvingAgainstBaseURL: false) else {
            throw GitHubError.network("Invalid URL")
        }
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw GitHubError.network("Invalid URL") }
        return url
    }

    /// Sends one request. Returns nil data on 304 (only possible when `conditional`).
    /// Never stores an ETag: callers commit it once the whole fetch succeeded. Throws mapped errors for non-2xx.
    private func perform(
        _ url: URL, conditional: Bool, accept: String = "application/vnd.github+json",
        method: String = "GET", body: Data? = nil, tracksRateLimit: Bool = true
    ) async throws -> (Data?, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = method
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        let key = url.absoluteString
        if conditional, let etag = etags[key] {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }

        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.send(request)
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch let error as URLError {
            throw GitHubError.network(error.localizedDescription)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw GitHubError.network(error.localizedDescription)
        }

        if tracksRateLimit, let limit = RateLimit(response: response) { latestRateLimit = limit }

        switch response.statusCode {
        case 200..<300:
            return (data, response)
        case 304:
            return (nil, response)
        case 401:
            throw GitHubError.unauthorized
        case 403:
            if response.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0"
                || response.value(forHTTPHeaderField: "Retry-After") != nil {
                throw GitHubError.rateLimited(resetAt: resetDate(response))
            }
            throw GitHubError.forbidden(Self.message(in: data))
        case 404:
            throw GitHubError.notFound
        case 429:
            throw GitHubError.rateLimited(resetAt: resetDate(response))
        default:
            throw GitHubError.http(response.statusCode)
        }
    }

    /// `Retry-After` seconds, else `X-RateLimit-Reset`, else now + 60 s.
    private func resetDate(_ response: HTTPURLResponse) -> Date {
        if let seconds = response.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init) {
            return Date().addingTimeInterval(seconds)
        }
        if let reset = response.value(forHTTPHeaderField: "X-RateLimit-Reset").flatMap(TimeInterval.init) {
            return Date(timeIntervalSince1970: reset)
        }
        return Date().addingTimeInterval(60)
    }

    private static func message(in data: Data) -> String? {
        struct Body: Decodable { let message: String }
        return try? JSONDecoder().decode(Body.self, from: data).message
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        do {
            return try decoder.decode(type, from: data)
        } catch {
            throw GitHubError.decoding(String(describing: error))
        }
    }

    private func nextLink(in response: HTTPURLResponse) -> URL? { link(rel: "next", in: response) }

    /// Extracts the URL with the given `rel` from the `Link` header.
    private func link(rel: String, in response: HTTPURLResponse) -> URL? {
        guard let header = response.value(forHTTPHeaderField: "Link") else { return nil }
        for part in header.split(separator: ",") {
            let pieces = part.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
            guard pieces.count >= 2, pieces.dropFirst().contains("rel=\"\(rel)\""),
                  let first = pieces.first, first.hasPrefix("<"), first.hasSuffix(">") else { continue }
            return URL(string: String(first.dropFirst().dropLast()))
        }
        return nil
    }
}
