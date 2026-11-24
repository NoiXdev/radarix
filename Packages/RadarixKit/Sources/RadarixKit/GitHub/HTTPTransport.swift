import Foundation

/// Abstraction over the network so the client can be tested without it.
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionTransport: HTTPTransport {
    /// Ephemeral and without a URL cache: GitHub marks authenticated responses cacheable, and a
    /// cache would write each request, Authorization header included, to disk. ETags are the
    /// only caching (in `GitHubClient`).
    private static let sharedSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()

    let session: URLSession

    public init() {
        session = Self.sharedSession
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }
}
