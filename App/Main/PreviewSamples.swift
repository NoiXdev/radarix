import Foundation
import RadarixKit

/// Plain sample data for the main window's previews.
enum PreviewSamples {
    static let radarix = RepoRef(
        id: RepoID(rawValue: 1), owner: "noixdev", name: "radarix", isPrivate: false, isArchived: false, isFork: false
    )
    static let pulsix = RepoRef(
        id: RepoID(rawValue: 2), owner: "noixdev", name: "pulsix", isPrivate: true, isArchived: false, isFork: false
    )
    static let dotfiles = RepoRef(
        id: RepoID(rawValue: 3), owner: "octocat", name: "dotfiles", isPrivate: false, isArchived: false, isFork: false
    )
    static let repos = [radarix, pulsix, dotfiles]

    static let records: [ItemRecord] = [
        record(radarix, 42, .pullRequest, "Add the grouped list layout", attention: .new, minutesAgo: 4,
               labels: [Label(name: "enhancement", colorHex: "a2eeef")], reviewers: ["octocat"]),
        record(radarix, 41, .issue, "Badges do not update after marking a repository as seen", attention: .updated,
               minutesAgo: 25, assignees: ["noidee"], comments: 5, commentsAtSeen: 3,
               body: "After using the context menu the counts stay until the next sync."),
        record(pulsix, 7, .pullRequest, "Bump actions/checkout from 4 to 5", attention: .new, minutesAgo: 60,
               author: Actor(login: "dependabot[bot]", apiType: "Bot")),
        record(pulsix, 5, .pullRequest, "Draft: inventory preview", attention: .seen, minutesAgo: 300, isDraft: true),
    ]

    static let entries: [ItemEntry] = records
        .sorted { $0.item.updatedAt > $1.item.updatedAt }
        .compactMap { record in
            repos.first { $0.id == record.item.key.repo }.map { ItemEntry(record: record, repo: $0) }
        }

    static let sections: [RepoSection] = repos.map { repo in
        RepoSection(
            repo: repo,
            counts: ItemFilter.counts(records.filter { $0.item.key.repo == repo.id }, bots: .badge),
            entries: entries.filter { $0.repo.id == repo.id },
            failure: repo == dotfiles ? .notFound : nil
        )
    }

    /// One account owning every sample repo: the sidebar shows no account header.
    static let accountSections = [AccountSection(login: "noidee", repos: sections)]

    /// Two accounts, each with the repos it owns.
    static let twoAccountSections = [
        AccountSection(login: "noidee", repos: sections.filter { $0.repo.owner == "noixdev" }),
        AccountSection(login: "octocat", repos: sections.filter { $0.repo.owner == "octocat" }),
    ]

    private static func record(
        _ repo: RepoRef, _ number: Int, _ kind: ItemKind, _ title: String, attention: Attention, minutesAgo: Double,
        author: Actor = Actor(login: "octocat", apiType: "User"), isDraft: Bool = false, labels: [Label] = [],
        assignees: [String] = [], reviewers: [String] = [], comments: Int = 0, commentsAtSeen: Int = 0,
        body: String = ""
    ) -> ItemRecord {
        let updatedAt = Date(timeIntervalSinceNow: -minutesAgo * 60)
        let item = Item(
            key: ItemKey(repo: repo.id, number: number), kind: kind, title: title,
            url: URL(string: "https://github.com/\(repo.fullName)/issues/\(number)")!,
            author: author, status: .open, isDraft: isDraft, labels: labels, assignees: assignees,
            requestedReviewers: reviewers, commentCount: comments, createdAt: updatedAt.addingTimeInterval(-86_400),
            updatedAt: updatedAt, bodyExcerpt: body
        )
        return ItemRecord(
            item: item, attention: attention, seenAt: attention == .seen ? updatedAt : nil, commentsAtSeen: commentsAtSeen
        )
    }
}
