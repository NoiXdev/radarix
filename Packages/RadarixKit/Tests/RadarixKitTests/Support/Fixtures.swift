import Foundation
import Testing
@testable import RadarixKit

let t0 = Date(timeIntervalSince1970: 1_800_000_000)
let t1 = t0.addingTimeInterval(3_600)
let t2 = t0.addingTimeInterval(7_200)

extension Item {
    static func fixture(
        repo: Int64 = 1,
        number: Int = 1,
        kind: ItemKind = .issue,
        title: String = "Fixture",
        author: String = "alice",
        status: ItemStatus = .open,
        isDraft: Bool = false,
        labels: [Label] = [],
        assignees: [String] = [],
        requestedReviewers: [String] = [],
        commentCount: Int = 0,
        createdAt: Date = t0,
        updatedAt: Date = t0,
        bodyExcerpt: String = ""
    ) -> Item {
        Item(
            key: ItemKey(repo: RepoID(rawValue: repo), number: number),
            kind: kind,
            title: title,
            url: URL(string: "https://github.com/o/r/issues/\(number)")!,
            author: Actor(login: author, apiType: "User"),
            status: status,
            isDraft: isDraft,
            labels: labels,
            assignees: assignees,
            requestedReviewers: requestedReviewers,
            commentCount: commentCount,
            createdAt: createdAt,
            updatedAt: updatedAt,
            bodyExcerpt: bodyExcerpt
        )
    }
}

/// Loads a JSON fixture from `Tests/RadarixKitTests/Fixtures`.
func fixtureJSON(_ name: String) throws -> String {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
    return try String(contentsOf: url, encoding: .utf8)
}
