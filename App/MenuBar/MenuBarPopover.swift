import AppKit
import RadarixKit
import SwiftUI

/// The menu bar extra's window: reads the controller and hands plain data to `MenuBarPopoverContent`.
/// Appearing marks nothing seen; only clicking an item or "Mark all as seen" does.
struct MenuBarPopover: View {
    /// The popover lists the newest items only.
    static let itemLimit = 10

    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings

    private var controller: RadarixController { model.controller }

    var body: some View {
        MenuBarPopoverContent(
            counts: controller.counts(in: nil),
            entries: entries,
            notices: notices,
            isSyncing: controller.isSyncing,
            lastSyncAt: controller.lastSyncAt,
            actions: actions
        )
    }

    /// The newest listed new and updated items, with the same bot rule as the label count.
    private var entries: [ItemEntry] {
        guard let account = controller.account else { return [] }
        let records = ItemFilter.visible(
            controller.records(in: nil),
            filter: FilterSet(),
            viewer: account.login,
            scope: controller.settings.botDisplay == .hidden ? .humans : .all
        )
        return records.prefix(Self.itemLimit).compactMap { record in
            account.repos[record.item.key.repo].map { ItemEntry(record: record, repo: $0.repo) }
        }
    }

    private var notices: [MenuBarNotice] {
        switch controller.auth {
        case .signedOut: return [.signedOut]
        case .needsReauth: return [.needsReauth] + syncNotices
        case .signedIn: return syncNotices
        }
    }

    private var syncNotices: [MenuBarNotice] {
        var notices: [MenuBarNotice] = []
        if controller.syncProblem == .offline { notices.append(.offline) }
        // From the owners request or the sync itself, like the main window's banner.
        if case .rateLimited(let until) = controller.syncProblem {
            notices.append(.rateLimited(until: until))
        } else if let until = controller.lastReport?.rateLimitedUntil {
            notices.append(.rateLimited(until: until))
        }
        return notices
    }

    private var actions: MenuBarActions {
        let model = model
        let controller = controller
        let openSettings = openSettings
        return MenuBarActions(
            open: { record in
                NSWorkspace.shared.open(record.item.url)
                controller.markSeen(record.item.key)
            },
            refresh: { Task { await controller.refresh() } },
            markAllSeen: { controller.markAllSeen() },
            openMain: { model.open(.main) },
            openSettings: {
                openSettings()
                NSApp.activate()
            },
            quit: { NSApp.terminate(nil) }
        )
    }
}

/// A state the popover reports above the items.
enum MenuBarNotice: Hashable {
    case signedOut, needsReauth, offline, rateLimited(until: Date)
}

/// What the popover's buttons do. The defaults do nothing, for previews.
struct MenuBarActions {
    /// Opens the item on GitHub and marks it seen.
    var open: @MainActor (ItemRecord) -> Void = { _ in }
    var refresh: @MainActor () -> Void = {}
    var markAllSeen: @MainActor () -> Void = {}
    var openMain: @MainActor () -> Void = {}
    var openSettings: @MainActor () -> Void = {}
    var quit: @MainActor () -> Void = {}
}

/// The popover's layout, fed with plain data.
struct MenuBarPopoverContent: View {
    let counts: AttentionCounts
    let entries: [ItemEntry]
    let notices: [MenuBarNotice]
    let isSyncing: Bool
    let lastSyncAt: Date?
    var actions = MenuBarActions()

    private var isSignedOut: Bool { notices.contains(.signedOut) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 8)
            if !notices.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(notices, id: \.self) { notice in
                        noticeRow(notice)
                    }
                }
                .padding(5)
            }
            Divider()
            items
            Divider()
            footer.padding(5)
        }
        .frame(width: 340)
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(counts.new) new · \(counts.updated) updated")
                    .font(.headline)
                    .monospacedDigit()
                if let lastSyncAt {
                    TimelineView(.everyMinute) { _ in
                        Text("Synced \(Text(lastSyncAt, format: .relative(presentation: .named)))")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            if isSyncing {
                ProgressView()
                    .controlSize(.small)
                    .help("Syncing…")
            } else {
                Button(action: actions.refresh) {
                    Label("Refresh", systemImage: "arrow.clockwise")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .help("Refresh")
                .disabled(isSignedOut || notices.contains(.needsReauth))
            }
        }
    }

    // MARK: Notices

    @ViewBuilder private func noticeRow(_ notice: MenuBarNotice) -> some View {
        switch notice {
        case .signedOut:
            MenuBarRowButton(action: actions.openSettings) {
                Label("Sign in to GitHub", systemImage: "person.crop.circle.badge.questionmark")
            }
        case .needsReauth:
            MenuBarRowButton(action: actions.openSettings) {
                Label {
                    Text("Sign in again")
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
            }
        case .offline:
            NoticeLabel(systemImage: "wifi.slash") {
                Text("Can't reach GitHub. Showing saved data.")
            }
        case .rateLimited(let until):
            TimelineView(.everyMinute) { context in
                if until > context.date {
                    NoticeLabel(systemImage: "hourglass") {
                        Text("GitHub's rate limit is reached. Radarix syncs again after \(Text(until, style: .time)).")
                    }
                }
            }
        }
    }

    // MARK: Items

    @ViewBuilder private var items: some View {
        if entries.isEmpty {
            if !isSignedOut {
                Text("Nothing new.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
            }
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(entries) { entry in
                    MenuBarItemRow(entry: entry) { actions.open(entry.record) }
                }
            }
            .padding(5)
        }
    }

    // MARK: Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 0) {
            MenuBarRowButton(action: actions.markAllSeen) { Text("Mark all as seen") }
                .disabled(counts.total == 0)
            MenuBarRowButton(action: actions.openMain) { Text("Open Radarix") }
            MenuBarRowButton(action: actions.openSettings) { Text("Settings…") }
            Divider().padding(.vertical, 4).padding(.horizontal, 7)
            MenuBarRowButton(action: actions.quit) { Text("Quit Radarix") }
        }
    }
}

/// One item: attention dot, kind icon, one-line title and `owner/name`. A click opens it and marks it seen.
private struct MenuBarItemRow: View {
    let entry: ItemEntry
    let open: () -> Void

    private var item: Item { entry.record.item }

    var body: some View {
        MenuBarRowButton(action: open) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                AttentionDot(attention: entry.record.attention)
                KindMarker(item: item)
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: item.title)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(verbatim: entry.repo.fullName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .help(Text(verbatim: item.title))
    }
}

/// A full-width, menu-like button that highlights under the pointer. Hovering does nothing else.
private struct MenuBarRowButton<Content: View>: View {
    let action: () -> Void
    @ViewBuilder let content: Content

    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isEnabled ? .primary : .tertiary)
        .background {
            if isHovered, isEnabled {
                RoundedRectangle(cornerRadius: 5).fill(.quaternary)
            }
        }
        .onHover { isHovered = $0 }
    }
}

/// A secondary, non-interactive state line.
private struct NoticeLabel<Message: View>: View {
    let systemImage: String
    @ViewBuilder let message: Message

    var body: some View {
        Label {
            message.fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: systemImage)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
    }
}

#Preview("Popover") {
    MenuBarPopoverContent(
        counts: ItemFilter.counts(PreviewSamples.records, bots: .badge),
        entries: PreviewSamples.entries.filter { $0.record.attention != .seen },
        notices: [.offline],
        isSyncing: false,
        lastSyncAt: Date(timeIntervalSinceNow: -180)
    )
}

#Preview("Popover, signed out") {
    MenuBarPopoverContent(counts: AttentionCounts(), entries: [], notices: [.signedOut], isSyncing: false, lastSyncAt: nil)
}

#Preview("Popover, nothing new") {
    MenuBarPopoverContent(
        counts: AttentionCounts(), entries: [], notices: [], isSyncing: true, lastSyncAt: Date(timeIntervalSinceNow: -60)
    )
}
