import Foundation

/// Decides whether a timeline contains activity by someone other than the viewer after a point in time.
enum ActivityProbe {
    /// - Parameters:
    ///   - itemAuthorIsViewer: `committed` events carry no GitHub login; they count as the viewer's
    ///     own when the item's author is the viewer, otherwise as other activity.
    static func hasOtherActivity(
        in entries: [TimelineEntryDTO], since: Date, viewers: ViewerLogins, itemAuthorIsViewer: Bool
    ) -> Bool {
        entries.contains { entry in
            guard let timestamp = timestamp(of: entry), timestamp > since else { return false }
            if entry.event == "committed" { return !itemAuthorIsViewer }
            guard let login = entry.actor?.login ?? entry.user?.login else { return true }
            return !viewers.contains(login)
        }
    }

    private static func timestamp(of entry: TimelineEntryDTO) -> Date? {
        let raw = entry.createdAt ?? entry.submittedAt ?? entry.committer?.date ?? entry.author?.date
        return raw.flatMap { ISO8601DateFormatter().date(from: $0) }
    }
}
