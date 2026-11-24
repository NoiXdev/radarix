import Foundation

/// A `radarix://` link that opens the app at an item, a repo or just the main window.
///
/// `radarix://item/<repoID>/<number>`, `radarix://repo/<repoID>`, `radarix://open`.
public enum DeepLink: Sendable, Equatable {
    case item(ItemKey), repo(RepoID), main

    public static let scheme = "radarix"

    /// Nil for another scheme, an unknown host, a query, a fragment, extra segments
    /// or a segment that is not a decimal integer above zero.
    public init?(url: URL) {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme?.lowercased() == Self.scheme,
              parts.user == nil, parts.password == nil, parts.port == nil,
              parts.query == nil, parts.fragment == nil,
              let host = parts.host?.lowercased()
        else { return nil }
        let path = parts.percentEncodedPath
        let segments: [Substring]
        if path.isEmpty {
            segments = []
        } else {
            guard path.hasPrefix("/") else { return nil }
            segments = path.dropFirst().split(separator: "/", omittingEmptySubsequences: false)
        }
        switch (host, segments.count) {
        case ("item", 2):
            guard let repo = Self.positive(segments[0]),
                  let number = Self.positive(segments[1]).flatMap(Int.init(exactly:))
            else { return nil }
            self = .item(ItemKey(repo: RepoID(rawValue: repo), number: number))
        case ("repo", 1):
            guard let repo = Self.positive(segments[0]) else { return nil }
            self = .repo(RepoID(rawValue: repo))
        case ("open", 0):
            self = .main
        default:
            return nil
        }
    }

    public var url: URL {
        let string = switch self {
        case .item(let key): "\(Self.scheme)://item/\(key.repo.rawValue)/\(key.number)"
        case .repo(let id): "\(Self.scheme)://repo/\(id.rawValue)"
        case .main: "\(Self.scheme)://open"
        }
        // Only a scheme, a fixed host and decimal digits: always a valid URL.
        return URL(string: string)!
    }

    /// Plain ASCII digits (no sign) forming a value above zero that fits `Int64`.
    private static func positive(_ segment: Substring) -> Int64? {
        guard !segment.isEmpty, segment.utf8.allSatisfy({ (0x30...0x39).contains($0) }),
              let value = Int64(segment), value > 0
        else { return nil }
        return value
    }
}
