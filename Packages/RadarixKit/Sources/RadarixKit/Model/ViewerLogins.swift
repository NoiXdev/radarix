import Foundation

/// The logins that count as "me": one per signed-in account. Compared case-insensitively.
public struct ViewerLogins: Sendable, Equatable {
    private let logins: Set<String>

    public init(_ logins: some Sequence<String>) {
        self.logins = Set(logins.map { $0.lowercased() })
    }

    public func contains(_ login: String) -> Bool {
        logins.contains(login.lowercased())
    }
}
