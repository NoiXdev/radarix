import Foundation

public enum GitHubError: Error, Equatable, Sendable {
    case unauthorized
    case forbidden(String?)
    case rateLimited(resetAt: Date)
    case notFound
    case http(Int)
    case network(String)
    case decoding(String)
}
