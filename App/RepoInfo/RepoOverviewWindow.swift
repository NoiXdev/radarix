import RadarixKit
import SwiftUI

/// Every watched repository in one table: stars, forks, open issues and PRs, and the last push.
/// It reads the counts the repository listing already carries, so it sends no request.
struct RepoOverviewWindow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openURL) private var openURL

    @State private var selection: Set<RepoID> = []
    /// Empty keeps the sidebar order.
    @State private var sortOrder: [RowComparator] = []

    /// One table row. A missing number (no listing yet) is nil and shows as a dash.
    struct Row: Identifiable {
        let repo: RepoRef
        let stats: RepoStats?
        /// The place in the sidebar order, which settles ties.
        let position: Int
        var id: RepoID { repo.id }
        var stars: Int? { stats?.stars }
        var forks: Int? { stats?.forks }
        var openIssuesAndPulls: Int? { stats?.openIssuesAndPulls }
        var pushedAt: Date? { stats?.pushedAt }
    }

    /// Orders rows by one column. A row without a value comes last in either direction.
    struct RowComparator: SortComparator, Hashable {
        enum Column: Hashable { case name, stars, forks, openIssuesAndPulls, pushedAt }

        let column: Column
        var order: SortOrder = .forward

        func compare(_ a: Row, _ b: Row) -> ComparisonResult {
            let result: ComparisonResult
            switch column {
            case .name:
                result = a.repo.fullName.localizedCaseInsensitiveCompare(b.repo.fullName)
            case .stars: result = Self.compare(a.stars, b.stars, order)
            case .forks: result = Self.compare(a.forks, b.forks, order)
            case .openIssuesAndPulls: result = Self.compare(a.openIssuesAndPulls, b.openIssuesAndPulls, order)
            case .pushedAt: result = Self.compare(a.pushedAt, b.pushedAt, order)
            }
            if result != .orderedSame {
                // The missing-last comparison already honors the order.
                return column == .name && order == .reverse ? Self.flip(result) : result
            }
            return a.position < b.position ? .orderedAscending : (a.position > b.position ? .orderedDescending : .orderedSame)
        }

        private static func compare<T: Comparable>(_ a: T?, _ b: T?, _ order: SortOrder) -> ComparisonResult {
            switch (a, b) {
            case (nil, nil): return .orderedSame
            case (nil, _): return .orderedDescending
            case (_, nil): return .orderedAscending
            case let (a?, b?):
                if a == b { return .orderedSame }
                let ascending = a < b
                return ascending == (order == .forward) ? .orderedAscending : .orderedDescending
            }
        }

        private static func flip(_ result: ComparisonResult) -> ComparisonResult {
            result == .orderedAscending ? .orderedDescending : .orderedAscending
        }
    }

    private var controller: RadarixController { model.controller }

    private var rows: [Row] {
        let ordered = controller.orderedRepos(in: controller.repos).flatMap(\.repos)
        let base = ordered.enumerated().map { Row(repo: $1, stats: controller.repoStats($1.id), position: $0) }
        return base.sorted(using: sortOrder)
    }

    var body: some View {
        let rows = rows
        Group {
            if rows.isEmpty {
                ContentUnavailableView(
                    "No repositories yet. Radarix fills this in after the first sync.",
                    systemImage: "tray"
                )
            } else {
                table(rows)
            }
        }
        .frame(minWidth: 520, minHeight: 280)
        .navigationTitle("Repository Overview")
        // A deep link arriving while this window is in front goes to the main window.
        .handlesExternalEvents(preferring: [], allowing: [])
    }

    private func table(_ rows: [Row]) -> some View {
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Repository", sortUsing: RowComparator(column: .name)) { row in
                HStack(spacing: 6) {
                    Text(verbatim: row.repo.fullName)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if row.repo.isArchived {
                        Image(systemName: "archivebox")
                            .foregroundStyle(.secondary)
                            .help("Archived")
                            .accessibilityLabel("Archived")
                    }
                    if row.repo.isPrivate {
                        Image(systemName: "lock")
                            .foregroundStyle(.secondary)
                            .help("Private")
                            .accessibilityLabel("Private")
                    }
                }
            }
            .width(min: 180, ideal: 260)
            TableColumn("Stars", sortUsing: RowComparator(column: .stars)) { row in
                number(row.stars)
            }
            .width(min: 60, ideal: 70)
            TableColumn("Forks", sortUsing: RowComparator(column: .forks)) { row in
                number(row.forks)
            }
            .width(min: 60, ideal: 70)
            TableColumn("Open issues & PRs", sortUsing: RowComparator(column: .openIssuesAndPulls)) { row in
                number(row.openIssuesAndPulls)
            }
            .width(min: 90, ideal: 120)
            TableColumn("Last push", sortUsing: RowComparator(column: .pushedAt)) { row in
                if let date = row.pushedAt {
                    Text(date, format: .relative(presentation: .named))
                } else {
                    Text(verbatim: "—").foregroundStyle(.secondary)
                }
            }
            .width(min: 90, ideal: 130)
        }
        .contextMenu(forSelectionType: RepoID.self) { ids in
            if !ids.isEmpty {
                Button("Repository Info…") { showInfo(ids) }
                Button("Open on GitHub") { openOnGitHub(ids) }
            }
        } primaryAction: { ids in
            showInfo(ids)
        }
    }

    private func number(_ value: Int?) -> some View {
        Group {
            if let value {
                Text(value, format: .number)
            } else {
                Text(verbatim: "—").foregroundStyle(.secondary)
            }
        }
        .monospacedDigit()
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private func showInfo(_ ids: Set<RepoID>) {
        // Capped at 5 windows (the first 5 in table order) so a large selection cannot flood the screen.
        let ordered = rows.map(\.id).filter { ids.contains($0) }
        for id in ordered.prefix(5) { openWindow(id: "repo-info", value: id) }
    }

    private func openOnGitHub(_ ids: Set<RepoID>) {
        for id in ids {
            if let url = controller.repos[id]?.repo.githubURL { openURL(url) }
        }
    }
}
