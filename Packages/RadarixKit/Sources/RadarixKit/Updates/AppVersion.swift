import Foundation

/// A plain `X.Y.Z` release version.
///
/// Pre-release and build suffixes are rejected rather than ignored, so a tag like `1.2.3-rc.1`
/// can never be mistaken for the final `1.2.3`.
public struct AppVersion: Comparable, Sendable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int

    public init?(_ string: String) {
        let body = string.hasPrefix("v") ? String(string.dropFirst()) : string
        let parts = body.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.allSatisfy({ $0.isASCII && $0.isNumber }), let n = Int(part) else { return nil }
            numbers.append(n)
        }
        major = numbers[0]
        minor = numbers.count > 1 ? numbers[1] : 0
        patch = numbers.count > 2 ? numbers[2] : 0
    }

    public var description: String { "\(major).\(minor).\(patch)" }

    public static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}
