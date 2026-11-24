import Foundation
import RadarixKit
import SwiftUI
import WidgetKit

@main
struct RadarixWidgetBundle: WidgetBundle {
    var body: some Widget {
        OverviewWidget()
    }
}

/// New and updated items in three sizes, for all repositories, one owner or one repository.
struct OverviewWidget: Widget {
    static let kind = "dev.noix.radarix.widget.overview"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: Self.kind, intent: ScopeIntent.self, provider: OverviewProvider()) { entry in
            OverviewWidgetView(entry: entry)
        }
        .configurationDisplayName("Radarix")
        .description("Shows new and updated items.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

/// What one widget shows: the snapshot as read (nil when missing), the resolved scope and its name.
struct OverviewEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot?
    let scope: WidgetScope
    let scopeName: String
    let filter: FilterSet

    init(date: Date = .now, snapshot: WidgetSnapshot?, scope: WidgetScope, filter: FilterSet = FilterSet()) {
        self.date = date
        self.snapshot = snapshot
        self.scope = scope
        self.filter = filter
        scopeName = Self.name(of: scope, in: snapshot)
    }

    init(date: Date = .now, snapshot: WidgetSnapshot?, configuration: ScopeIntent) {
        self.init(
            date: date, snapshot: snapshot, scope: ScopeEntity.scope(forID: configuration.scope?.id, in: snapshot),
            filter: configuration.filter)
    }

    var summary: WidgetSnapshot.Summary {
        (snapshot ?? .signedOut).summary(for: scope, filter: filter)
    }

    /// What the active filter shows, or nil when nothing is filtered.
    var filterCaption: String? { filter.caption }

    /// How old the data is at `date`; nil unless signed in.
    var freshness: Freshness? {
        guard let snapshot, snapshot.status == .ok else { return nil }
        let isStale = snapshot.syncedAt.map { date >= Self.staleDate(of: $0) } ?? false
        // An account that needs sign-in matters more than how old the data is.
        if !snapshot.reauthLogins.isEmpty { return .needsSignIn(snapshot.reauthLogins, isStale: isStale) }
        guard let syncedAt = snapshot.syncedAt else { return .waiting }
        return isStale ? .stale(since: syncedAt) : .updated(syncedAt)
    }

    static func staleDate(of syncedAt: Date) -> Date {
        syncedAt.addingTimeInterval(WidgetSnapshot.staleAfter)
    }

    private static func name(of scope: WidgetScope, in snapshot: WidgetSnapshot?) -> String {
        switch scope {
        case .all:
            return String(localized: "All repositories")
        case .owner(let login):
            return login
        case .repo(let id):
            return snapshot?.repos.first(where: { $0.id == id })?.fullName ?? String(localized: "All repositories")
        }
    }
}

/// How old a signed-in widget's data is.
enum Freshness: Equatable {
    /// Signed in, no sync has completed yet.
    case waiting
    case updated(Date)
    /// Radarix has not synced for `WidgetSnapshot.staleAfter`, for example because it is not running.
    case stale(since: Date)
    /// One or more accounts need to sign in again while the rest still sync. Wins over the age note.
    case needsSignIn([String], isStale: Bool)

    var needsSignIn: Bool {
        if case .needsSignIn = self { true } else { false }
    }
}

/// Read fresh from the snapshot: the current entry, and one that shows the data as stale once it
/// is `WidgetSnapshot.staleAfter` old. The app reloads the timelines when the snapshot changes
/// and well before that age while it syncs, so the policy is `.never`.
struct OverviewProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> OverviewEntry {
        OverviewEntry(snapshot: .sample, scope: .all)
    }

    func snapshot(for configuration: ScopeIntent, in context: Context) async -> OverviewEntry {
        if context.isPreview { return OverviewEntry(snapshot: .sample, scope: .all) }
        return OverviewEntry(snapshot: SnapshotReader.load(), configuration: configuration)
    }

    func timeline(for configuration: ScopeIntent, in context: Context) async -> Timeline<OverviewEntry> {
        let snapshot = SnapshotReader.load()
        let now = Date.now
        var entries = [OverviewEntry(date: now, snapshot: snapshot, configuration: configuration)]
        // Already stale data shows as stale in the current entry.
        if snapshot?.status == .ok, let syncedAt = snapshot?.syncedAt {
            let staleDate = OverviewEntry.staleDate(of: syncedAt)
            if staleDate > now {
                entries.append(OverviewEntry(date: staleDate, snapshot: snapshot, configuration: configuration))
            }
        }
        return Timeline(entries: entries, policy: .never)
    }
}

/// Reads the snapshot the app writes into the shared App Group directory. Never writes, and never
/// touches credentials or the network.
enum SnapshotReader {
    /// Nil when the file is missing or unreadable; the widget then shows the signed-out state.
    static func load() -> WidgetSnapshot? {
        let store = FileStore(directory: FileStore.defaultDirectory(appGroup: infoValue("RadarixAppGroup")))
        return try? store.loadSnapshot()
    }

    /// An empty value or an unexpanded `$(…)` build setting means "not configured".
    private static func infoValue(_ key: String) -> String {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String else { return "" }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.contains("$(") ? "" : trimmed
    }
}
