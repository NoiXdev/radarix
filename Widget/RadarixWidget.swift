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

    init(date: Date = .now, snapshot: WidgetSnapshot?, scope: WidgetScope) {
        self.date = date
        self.snapshot = snapshot
        self.scope = scope
        scopeName = Self.name(of: scope, in: snapshot)
    }

    init(snapshot: WidgetSnapshot?, configuration: ScopeIntent) {
        self.init(snapshot: snapshot, scope: ScopeEntity.scope(forID: configuration.scope?.id, in: snapshot))
    }

    var summary: WidgetSnapshot.Summary {
        (snapshot ?? .signedOut).summary(for: scope)
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

/// One entry per timeline, read fresh from the snapshot. The app reloads the timelines after
/// every snapshot write, so the policy is `.never`.
struct OverviewProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> OverviewEntry {
        OverviewEntry(snapshot: .sample, scope: .all)
    }

    func snapshot(for configuration: ScopeIntent, in context: Context) async -> OverviewEntry {
        if context.isPreview { return OverviewEntry(snapshot: .sample, scope: .all) }
        return OverviewEntry(snapshot: SnapshotReader.load(), configuration: configuration)
    }

    func timeline(for configuration: ScopeIntent, in context: Context) async -> Timeline<OverviewEntry> {
        let entry = OverviewEntry(snapshot: SnapshotReader.load(), configuration: configuration)
        return Timeline(entries: [entry], policy: .never)
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
