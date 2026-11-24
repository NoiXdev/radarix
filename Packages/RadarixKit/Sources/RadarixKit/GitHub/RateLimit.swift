import Foundation

public struct RateLimit: Sendable, Equatable {
    public let limit: Int
    public let remaining: Int
    public let resetAt: Date

    public init(limit: Int, remaining: Int, resetAt: Date) {
        self.limit = limit
        self.remaining = remaining
        self.resetAt = resetAt
    }

    /// Parses the `X-RateLimit-*` headers; nil when any of them is missing.
    init?(response: HTTPURLResponse) {
        guard let limit = response.value(forHTTPHeaderField: "X-RateLimit-Limit").flatMap(Int.init),
              let remaining = response.value(forHTTPHeaderField: "X-RateLimit-Remaining").flatMap(Int.init),
              let reset = response.value(forHTTPHeaderField: "X-RateLimit-Reset").flatMap(TimeInterval.init)
        else { return nil }
        self.init(limit: limit, remaining: remaining, resetAt: Date(timeIntervalSince1970: reset))
    }
}
