import RadarixKit
import SwiftUI
import WidgetKit

extension Color {
    /// `#2F7CF6`, for new items.
    static let attentionNew = Color(red: 0x2F / 255, green: 0x7C / 255, blue: 0xF6 / 255)
    /// `#F5A524`, for updated items. An accent only: too light for text on a light background.
    static let attentionUpdated = Color(red: 0xF5 / 255, green: 0xA5 / 255, blue: 0x24 / 255)
    /// `#0B1524`, for text on `attentionUpdated`.
    static let attentionUpdatedInk = Color(red: 0x0B / 255, green: 0x15 / 255, blue: 0x24 / 255)
}

/// Picks the layout for the widget's size and status. Shows data only; nothing here writes.
struct OverviewWidgetView: View {
    let entry: OverviewEntry

    @Environment(\.widgetFamily) private var family

    var body: some View {
        content
            .containerBackground(.background, for: .widget)
    }

    @ViewBuilder private var content: some View {
        switch entry.snapshot?.status {
        case .ok:
            switch family {
            case .systemSmall:
                SmallOverview(summary: entry.summary, filterCaption: entry.filterCaption, freshness: entry.freshness)
            case .systemLarge:
                LargeOverview(
                    summary: entry.summary, scopeName: entry.scopeName, filterCaption: entry.filterCaption,
                    freshness: entry.freshness)
            default:
                MediumOverview(
                    summary: entry.summary, scopeName: entry.scopeName, filterCaption: entry.filterCaption,
                    freshness: entry.freshness)
            }
        case .needsReauth:
            StatusMessage(text: "Sign in again in Radarix.", systemImage: "exclamationmark.triangle.fill")
        case .signedOut, nil:
            StatusMessage(text: "Open Radarix to sign in.", systemImage: "person.crop.circle.badge.questionmark")
        }
    }
}

// MARK: Sizes

/// The new and updated counts and the busiest repository. A tap opens that repository.
/// Stale data, none synced yet, or an account to sign in again shows that note instead of the
/// repository, and a tap opens Radarix.
struct SmallOverview: View {
    let summary: WidgetSnapshot.Summary
    var filterCaption: String?
    let freshness: Freshness?

    private var busiest: WidgetSnapshot.RepoEntry? { showsNote ? nil : summary.busiestRepo }

    private var showsNote: Bool { notesFreshness || freshness?.needsSignIn == true }

    private var notesFreshness: Bool {
        switch freshness {
        case .stale, .waiting, .needsSignIn(_, isStale: true): true
        case .updated, .needsSignIn(_, isStale: false), nil: false
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            CountTile(count: summary.newCount, isLowerBound: summary.isLowerBound, label: "new", fill: .attentionNew, ink: .white)
                .accessibilityLabel(
                    summary.isLowerBound
                        ? Text("at least \(summary.newCount) new items") : Text("\(summary.newCount) new items"))
            CountTile(
                count: summary.updatedCount, isLowerBound: summary.isLowerBound, label: "updated",
                fill: .attentionUpdated, ink: .attentionUpdatedInk
            )
            .accessibilityLabel(
                summary.isLowerBound
                    ? Text("at least \(summary.updatedCount) updated items") : Text("\(summary.updatedCount) updated items"))
            if let filterCaption {
                FilterCaption(text: filterCaption)
            }
            if let freshness, showsNote {
                FreshnessNote(freshness: freshness)
                    .font(.caption2)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Group {
                    if let busiest {
                        Text(verbatim: busiest.name)
                    } else {
                        Text("Nothing new.").foregroundStyle(.secondary)
                    }
                }
                .font(.caption)
                .lineLimit(1)
            }
        }
        .widgetURL(busiest.map { DeepLink.repo($0.id).url } ?? DeepLink.main.url)
    }
}

/// The summary line and the newest 4 items.
struct MediumOverview: View {
    let summary: WidgetSnapshot.Summary
    let scopeName: String
    var filterCaption: String?
    let freshness: Freshness?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SummaryHeader(summary: summary, scopeName: scopeName, filterCaption: filterCaption, freshness: freshness)
            if summary.items.isEmpty {
                NothingNew()
            } else {
                // The caption takes a line, so a filtered widget lists one item fewer.
                ItemList(items: Array(summary.items.prefix(filterCaption == nil ? 4 : 3)), repos: summary.repos)
                Spacer(minLength: 0)
            }
        }
        .widgetURL(DeepLink.main.url)
    }
}

/// The summary, up to 4 repositories with their counts, then the newest 5 items.
struct LargeOverview: View {
    let summary: WidgetSnapshot.Summary
    let scopeName: String
    var filterCaption: String?
    let freshness: Freshness?

    private var busyRepos: [WidgetSnapshot.RepoEntry] {
        Array(summary.repos.filter { $0.newCount + $0.updatedCount > 0 }.prefix(4))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SummaryHeader(summary: summary, scopeName: scopeName, filterCaption: filterCaption, freshness: freshness)
            if summary.items.isEmpty, busyRepos.isEmpty {
                NothingNew()
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(busyRepos) { repo in
                        RepoLink(repo: repo)
                    }
                }
                Divider()
                ItemList(items: Array(summary.items.prefix(5)), repos: summary.repos)
                Spacer(minLength: 0)
            }
        }
        .widgetURL(DeepLink.main.url)
    }
}

// MARK: Parts

/// "3 new · 2 updated", the scope's name, then how old the data is.
private struct SummaryHeader: View {
    let summary: WidgetSnapshot.Summary
    let scopeName: String
    let filterCaption: String?
    let freshness: Freshness?

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                counts
                    .font(.headline)
                    .monospacedDigit()
                    .lineLimit(1)
                    .layoutPriority(1)
                Spacer(minLength: 0)
                Text(verbatim: scopeName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if let filterCaption {
                FilterCaption(text: filterCaption)
            }
            if let freshness {
                FreshnessNote(freshness: freshness)
                    .font(.caption2)
                    .lineLimit(1)
            }
        }
    }

    /// A trailing "+" on each count says that the widget may be missing items.
    private var counts: Text {
        summary.isLowerBound
            ? Text("\(summary.newCount)+ new · \(summary.updatedCount)+ updated")
            : Text("\(summary.newCount) new · \(summary.updatedCount) updated")
    }
}

/// What the widget's filter shows, for example "Assigned to me · Pull requests".
private struct FilterCaption: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "line.3.horizontal.decrease")
            .labelStyle(.titleAndIcon)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
    }
}

/// "Updated 5 minutes ago", "Waiting for the first sync." or, for stale data, when it was last
/// updated and that Radarix needs to run. Accounts that need sign-in replace all of these.
private struct FreshnessNote: View {
    let freshness: Freshness

    var body: some View {
        switch freshness {
        case .waiting:
            Text("Waiting for the first sync.")
                .foregroundStyle(.secondary)
        case .updated(let date):
            Text("Updated \(RelativeTime.text(date))")
                .foregroundStyle(.secondary)
        case .needsSignIn(let logins, _):
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                if logins.count == 1, let login = logins.first {
                    Text("\(login): sign in again")
                } else {
                    Text("\(logins.count) accounts need sign-in")
                }
            }
        case .stale(let date):
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                Text("Not updated since \(Text(date, format: .dateTime.day().month(.abbreviated).hour().minute())). Open Radarix.")
            }
        }
    }
}

/// A live, compact relative time such as "5 minutes ago": one unit, no seconds.
private enum RelativeTime {
    static func text(_ date: Date) -> Text {
        Text(.currentDate, format: .reference(to: date, allowedFields: [.year, .month, .day, .hour, .minute], maxFieldCount: 1))
    }
}

/// A full-width bar with a count and its label, on the attention color.
private struct CountTile: View {
    let count: Int
    let isLowerBound: Bool
    let label: LocalizedStringKey
    let fill: Color
    let ink: Color

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(isLowerBound ? "\(count.formatted())+" : count.formatted())
                .font(.system(.title, design: .rounded, weight: .bold))
                .monospacedDigit()
                .minimumScaleFactor(0.6)
                .widgetAccentable()
            Text(label)
                .font(.caption.weight(.semibold))
            Spacer(minLength: 0)
        }
        .lineLimit(1)
        .foregroundStyle(ink)
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(fill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .ignore)
    }
}

/// Item rows, each a link that opens the item in Radarix.
private struct ItemList: View {
    let items: [WidgetSnapshot.ItemEntry]
    let repos: [WidgetSnapshot.RepoEntry]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(items) { item in
                Link(destination: DeepLink.item(item.key).url) {
                    ItemRow(item: item, repoName: repos.first(where: { $0.id == item.key.repo })?.fullName)
                }
            }
        }
    }
}

/// Attention dot, kind icon, one-line title, then `owner/name`, the relative time and a bot badge.
private struct ItemRow: View {
    let item: WidgetSnapshot.ItemEntry
    let repoName: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            AttentionDot(attention: item.attention)
            Image(systemName: item.kind == .pullRequest ? "arrow.triangle.pull" : "exclamationmark.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 12)
                .accessibilityLabel(item.kind == .pullRequest ? Text("Pull request") : Text("Issue"))
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: item.title)
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    if let repoName {
                        Text(verbatim: repoName)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    RelativeTime.text(item.updatedAt)
                        .lineLimit(1)
                        .layoutPriority(1)
                    if item.isDraft {
                        Text("Draft")
                    }
                    if let bot = item.botName {
                        BotBadge(name: bot)
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// `owner/name` and its new and updated counts; a link that opens the repository in Radarix.
private struct RepoLink: View {
    let repo: WidgetSnapshot.RepoEntry

    var body: some View {
        Link(destination: DeepLink.repo(repo.id).url) {
            HStack(spacing: 6) {
                Text(verbatim: repo.fullName)
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                if repo.newCount > 0 {
                    CountBadge(text: repo.newCount.formatted(), fill: .attentionNew, ink: .white)
                        .accessibilityLabel(Text("\(repo.newCount) new items"))
                }
                if repo.updatedCount > 0 {
                    CountBadge(text: repo.updatedCount.formatted(), fill: .attentionUpdated, ink: .attentionUpdatedInk)
                        .accessibilityLabel(Text("\(repo.updatedCount) updated items"))
                }
            }
        }
    }
}

/// A blue dot for new, an amber dot for updated.
private struct AttentionDot: View {
    let attention: Attention

    var body: some View {
        Circle()
            .fill(attention == .updated ? Color.attentionUpdated : Color.attentionNew)
            .frame(width: 7, height: 7)
            .accessibilityLabel(attention == .updated ? Text("Updated") : Text("New"))
    }
}

/// A small capsule with a count.
private struct CountBadge: View {
    let text: String
    let fill: Color
    let ink: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(ink)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(fill, in: Capsule())
    }
}

/// The bot's display name in a small capsule.
private struct BotBadge: View {
    let name: String

    var body: some View {
        Text(verbatim: name)
            .font(.caption2)
            .lineLimit(1)
            .padding(.horizontal, 4)
            .background(.quaternary, in: Capsule())
            .accessibilityLabel(Text("Created by \(name)"))
    }
}

private struct NothingNew: View {
    var body: some View {
        Text("Nothing new.")
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A centered note for the signed-out and sign-in-again states. A tap opens Radarix.
private struct StatusMessage: View {
    let text: LocalizedStringKey
    let systemImage: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(.secondary)
            Text(text)
                .font(.callout)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .widgetURL(DeepLink.main.url)
    }
}

// MARK: Sample data

extension FilterSet {
    /// Updated pull requests, for the filtered previews.
    static var samplePullRequests: FilterSet {
        var filter = FilterSet()
        filter.new = false
        filter.pullRequests = true
        return filter
    }
}

extension WidgetSnapshot {
    /// For the placeholder, the widget gallery and previews.
    static let sample: WidgetSnapshot = {
        func item(
            _ repo: Int64, _ number: Int, _ kind: ItemKind, _ title: String, _ attention: Attention,
            minutesAgo: Double, draft: Bool = false, bot: String? = nil
        ) -> ItemEntry {
            ItemEntry(
                key: ItemKey(repo: RepoID(rawValue: repo), number: number), kind: kind, title: title,
                attention: attention, updatedAt: Date(timeIntervalSinceNow: -minutesAgo * 60), isDraft: draft,
                botName: bot)
        }
        return WidgetSnapshot(
            status: .ok, logins: ["octo"], reauthLogins: [], syncedAt: Date(timeIntervalSinceNow: -120),
            repos: [
                RepoEntry(
                    id: RepoID(rawValue: 1), owner: "acme", name: "api", newCount: 2, updatedCount: 1,
                    items: [
                        item(1, 412, .pullRequest, "Add pagination to the search endpoint", .new, minutesAgo: 4),
                        item(1, 409, .issue, "Timeouts when exporting large reports", .updated, minutesAgo: 35),
                        item(1, 415, .pullRequest, "Bump the HTTP client to 5.2", .new, minutesAgo: 90, bot: "Dependabot"),
                    ]),
                RepoEntry(
                    id: RepoID(rawValue: 2), owner: "acme", name: "web", newCount: 1, updatedCount: 1,
                    items: [
                        item(2, 88, .pullRequest, "Dark mode for the settings page", .updated, minutesAgo: 12, draft: true),
                        item(2, 91, .issue, "Login button misaligned on narrow screens", .new, minutesAgo: 150),
                    ]),
                RepoEntry(
                    id: RepoID(rawValue: 3), owner: "octo", name: "dotfiles", newCount: 0, updatedCount: 1,
                    items: [item(3, 7, .issue, "Shell prompt slow in large repositories", .updated, minutesAgo: 300)]),
                RepoEntry(id: RepoID(rawValue: 4), owner: "octo", name: "notes", newCount: 0, updatedCount: 0, items: []),
            ])
    }()

    static let sampleEmpty = WidgetSnapshot(
        status: .ok, logins: ["octo"], reauthLogins: [], syncedAt: .now,
        repos: [RepoEntry(id: RepoID(rawValue: 4), owner: "octo", name: "notes", newCount: 0, updatedCount: 0, items: [])])

    static let sampleNeedsReauth = WidgetSnapshot(
        status: .needsReauth, logins: ["octo"], reauthLogins: ["octo"], syncedAt: nil, repos: [])

    /// Two accounts, one of which needs to sign in again, for the sign-in line.
    static let sampleOneReauth: WidgetSnapshot = {
        var snapshot = sample
        snapshot.logins = ["octo", "acme-bot"]
        snapshot.reauthLogins = ["acme-bot"]
        return snapshot
    }()

    /// Last synced a day ago, for the stale note.
    static let sampleStale: WidgetSnapshot = {
        var snapshot = sample
        snapshot.syncedAt = Date(timeIntervalSinceNow: -86_400)
        return snapshot
    }()

    /// Signed in, no sync completed yet.
    static let sampleWaiting: WidgetSnapshot = {
        var snapshot = sampleEmpty
        snapshot.syncedAt = nil
        return snapshot
    }()
}

#Preview("Small", as: .systemSmall) {
    OverviewWidget()
} timeline: {
    OverviewEntry(snapshot: .sample, scope: .all)
    OverviewEntry(snapshot: .sampleEmpty, scope: .all)
    OverviewEntry(snapshot: .sampleStale, scope: .all)
    OverviewEntry(snapshot: .sampleOneReauth, scope: .all)
    OverviewEntry(snapshot: .sampleWaiting, scope: .all)
    OverviewEntry(snapshot: nil, scope: .all)
    OverviewEntry(snapshot: .sample, scope: .all, filter: .samplePullRequests)
}

#Preview("Medium", as: .systemMedium) {
    OverviewWidget()
} timeline: {
    OverviewEntry(snapshot: .sample, scope: .all)
    OverviewEntry(snapshot: .sample, scope: .owner("acme"))
    OverviewEntry(snapshot: .sampleEmpty, scope: .all)
    OverviewEntry(snapshot: .sampleStale, scope: .all)
    OverviewEntry(snapshot: .sampleOneReauth, scope: .all)
    OverviewEntry(snapshot: .sampleNeedsReauth, scope: .all)
    OverviewEntry(snapshot: .sample, scope: .all, filter: .samplePullRequests)
}

#Preview("Large", as: .systemLarge) {
    OverviewWidget()
} timeline: {
    OverviewEntry(snapshot: .sample, scope: .all)
    OverviewEntry(snapshot: .sample, scope: .repo(RepoID(rawValue: 2)))
    OverviewEntry(snapshot: .sampleEmpty, scope: .all)
    OverviewEntry(snapshot: .sampleStale, scope: .all)
    OverviewEntry(snapshot: .signedOut, scope: .all)
    OverviewEntry(snapshot: .sample, scope: .all, filter: .samplePullRequests)
}
