import Foundation

public struct PlannedNotification: Sendable, Equatable {
    public enum Content: Sendable, Equatable {
        /// `.new` or `.updated`.
        case item(Item, Attention)
        case summary(repo: RepoRef, newCount: Int, updatedCount: Int)
    }

    /// `item-<repoID>-<number>` or `repo-<repoID>`.
    public let id: String
    public let content: Content

    public init(id: String, content: Content) {
        self.id = id
        self.content = content
    }
}

/// Decides which notifications a sync report deserves. Pure: the app posts them and formats the text.
public enum NotificationPlanner {
    /// More notify-worthy items than this in one repo collapse into one summary.
    public static let summaryThreshold = 3

    public static func plan(_ report: SyncReport, account: AccountData, settings: AppSettings) -> [PlannedNotification] {
        var candidates: [(item: Item, attention: Attention)] = report.newItems.map { ($0, .new) }
        if settings.notifyUpdated {
            let alreadyNew = Set(report.newItems.map(\.key))
            candidates += report.updatedItems.filter { !alreadyNew.contains($0.key) }.map { ($0, .updated) }
        }

        var groups: [RepoID: (repo: RepoRef, entries: [(item: Item, attention: Attention)])] = [:]
        for candidate in candidates {
            let repoID = candidate.item.key.repo
            guard let repo = account.repos[repoID]?.repo,
                !account.watch.notificationsOff.contains(repoID)
            else { continue }
            if candidate.item.author.isBot, settings.botDisplay == .hidden || !settings.notifyBots { continue }
            groups[repoID, default: (repo, [])].entries.append(candidate)
        }

        let ordered = groups.values.sorted { lhs, rhs in
            let order = lhs.repo.fullName.caseInsensitiveCompare(rhs.repo.fullName)
            if order != .orderedSame { return order == .orderedAscending }
            return lhs.repo.id.rawValue < rhs.repo.id.rawValue
        }

        var planned: [PlannedNotification] = []
        for group in ordered {
            if group.entries.count > summaryThreshold {
                let newCount = group.entries.filter { $0.attention == .new }.count
                planned.append(
                    PlannedNotification(
                        id: "repo-\(group.repo.id.rawValue)",
                        content: .summary(
                            repo: group.repo, newCount: newCount, updatedCount: group.entries.count - newCount)))
            } else {
                let sorted = group.entries.sorted { lhs, rhs in
                    if lhs.item.updatedAt != rhs.item.updatedAt { return lhs.item.updatedAt > rhs.item.updatedAt }
                    return lhs.item.key.number < rhs.item.key.number
                }
                for entry in sorted {
                    planned.append(
                        PlannedNotification(
                            id: "item-\(group.repo.id.rawValue)-\(entry.item.key.number)",
                            content: .item(entry.item, entry.attention)))
                }
            }
        }
        return planned
    }
}
