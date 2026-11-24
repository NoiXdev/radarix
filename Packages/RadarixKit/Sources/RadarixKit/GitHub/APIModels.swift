import Foundation

/// Wire shapes of the GitHub REST responses. Decoded with `convertFromSnakeCase` and `.iso8601`,
/// so properties use camelCase. Internal: the public surface is the model types.

struct UserDTO: Decodable {
    let id: Int64
    let login: String
}

struct OrgDTO: Decodable {
    let login: String
}

struct RepoDTO: Decodable {
    struct Owner: Decodable { let login: String }
    let id: Int64
    let name: String
    let owner: Owner
    let `private`: Bool
    let archived: Bool
    let fork: Bool
}

struct IssueDTO: Decodable {
    struct User: Decodable {
        let login: String
        let type: String
    }
    struct LabelDTO: Decodable {
        let name: String
        let color: String
    }
    struct Assignee: Decodable { let login: String }
    struct PullRequestInfo: Decodable { let mergedAt: Date? }

    let number: Int
    let title: String
    let state: String
    let htmlUrl: URL
    let user: User
    let labels: [LabelDTO]
    let assignees: [Assignee]
    let comments: Int
    let createdAt: Date
    let updatedAt: Date
    let body: String?
    let pullRequest: PullRequestInfo?
}

struct PullDTO: Decodable {
    struct Reviewer: Decodable { let login: String }
    let number: Int
    let draft: Bool?
    let requestedReviewers: [Reviewer]?
}

/// Timeline entries come in many shapes; everything is optional so unknown events never fail decoding.
/// Timestamps stay strings and are parsed leniently by the probe.
struct TimelineEntryDTO: Decodable {
    struct Login: Decodable { let login: String? }
    struct GitIdentity: Decodable { let date: String? }

    let event: String?
    let createdAt: String?
    let submittedAt: String?
    let actor: Login?
    let user: Login?
    let author: GitIdentity?
    let committer: GitIdentity?
}

extension IssueDTO {
    private static let excerptLength = 280

    func toItem(repo: RepoID) -> Item {
        let isPR = pullRequest != nil
        let status: ItemStatus
        if pullRequest?.mergedAt != nil {
            status = .merged
        } else if state == "closed" {
            status = .closed
        } else {
            status = .open
        }
        return Item(
            key: ItemKey(repo: repo, number: number),
            kind: isPR ? .pullRequest : .issue,
            title: title,
            url: htmlUrl,
            author: Actor(login: user.login, apiType: user.type),
            status: status,
            isDraft: false,
            labels: labels.map { Label(name: $0.name, colorHex: $0.color) },
            assignees: assignees.map(\.login),
            requestedReviewers: [],
            commentCount: comments,
            createdAt: createdAt,
            updatedAt: updatedAt,
            bodyExcerpt: String((body ?? "").prefix(Self.excerptLength)).trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
}
