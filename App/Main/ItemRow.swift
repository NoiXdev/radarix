import RadarixKit
import SwiftUI

extension Color {
    /// `#2F7CF6`, for new items.
    static let attentionNew = Color(red: 0x2F / 255, green: 0x7C / 255, blue: 0xF6 / 255)
    /// `#F5A524`, for updated items.
    static let attentionUpdated = Color(red: 0xF5 / 255, green: 0xA5 / 255, blue: 0x24 / 255)
}

/// One issue or pull request in a list.
struct ItemRow: View {
    let entry: ItemEntry
    /// Off inside a section that already names the repository.
    var showsRepo = true
    var showsBotBadge = true

    private var item: Item { entry.record.item }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            AttentionDot(attention: entry.record.attention)
            KindMarker(item: item)
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: item.title)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    if showsRepo {
                        Text(verbatim: entry.repo.name)
                    }
                    Text(verbatim: "#\(item.key.number)")
                    if item.isDraft { Text("Draft") }
                    RelativeTime(date: item.updatedAt)
                    if showsBotBadge, let bot = item.author.botDisplayName {
                        BotBadge(name: bot)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if entry.record.attention == .updated, entry.record.newComments > 0 {
                    Text("\(entry.record.newComments) new comments")
                        .font(.caption)
                        .foregroundStyle(Color.attentionUpdated)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

/// A blue dot for new, an amber dot for updated, an empty slot for seen.
struct AttentionDot: View {
    let attention: Attention

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .accessibilityLabel(label)
            .accessibilityHidden(attention == .seen)
    }

    private var color: Color {
        switch attention {
        case .new: .attentionNew
        case .updated: .attentionUpdated
        case .seen: .clear
        }
    }

    private var label: LocalizedStringKey {
        switch attention {
        case .new: "New"
        case .updated: "Updated"
        case .seen: "Seen"
        }
    }
}

/// Pull request or issue, colored by status; a draft is secondary.
struct KindMarker: View {
    let item: Item

    var body: some View {
        Image(systemName: item.kind == .pullRequest ? "arrow.triangle.pull" : "exclamationmark.circle")
            .foregroundStyle(color)
            .accessibilityLabel(item.kind == .pullRequest ? LocalizedStringKey("Pull request") : LocalizedStringKey("Issue"))
            .help(StatusText.label(for: item))
    }

    private var color: Color {
        if item.isDraft { return .secondary }
        return switch item.status {
        case .open: .green
        case .merged: .purple
        case .closed: .red
        }
    }
}

/// The status as the user reads it: open, draft, merged or closed.
enum StatusText {
    static func label(for item: Item) -> LocalizedStringKey {
        if item.isDraft, item.status == .open { return "Draft" }
        return switch item.status {
        case .open: "Open"
        case .merged: "Merged"
        case .closed: "Closed"
        }
    }
}

/// Small capsules with the new and updated counts; nothing for zero.
struct AttentionBadges: View {
    let counts: AttentionCounts

    var body: some View {
        HStack(spacing: 4) {
            if counts.new > 0 {
                CountBadge(count: counts.new, color: .attentionNew)
                    .accessibilityLabel("\(counts.new) new")
            }
            if counts.updated > 0 {
                CountBadge(count: counts.updated, color: .attentionUpdated)
                    .accessibilityLabel("\(counts.updated) updated")
            }
        }
    }
}

private struct CountBadge: View {
    let count: Int
    let color: Color

    var body: some View {
        Text(count, format: .number)
            .font(.caption2.weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(color, in: Capsule())
    }
}

/// The bot's display name in a capsule.
struct BotBadge: View {
    let name: String

    var body: some View {
        Label {
            Text(verbatim: name)
        } icon: {
            Image(systemName: "gearshape.2")
        }
        .labelStyle(.titleAndIcon)
        .font(.caption2)
        .padding(.horizontal, 5)
        .padding(.vertical, 1)
        .background(.quaternary, in: Capsule())
        .help("Created by a bot")
    }
}

/// "5 minutes ago", kept current.
struct RelativeTime: View {
    let date: Date

    var body: some View {
        TimelineView(.everyMinute) { _ in
            Text(date, format: .relative(presentation: .named))
        }
    }
}

extension View {
    /// The item context menu for a list of entries; a double click opens the item on GitHub.
    func itemContextMenu(entries: [ItemEntry], actions: ItemActions) -> some View {
        contextMenu(forSelectionType: ItemKey.self) { keys in
            if let key = keys.first, let entry = entries.first(where: { $0.id == key }) {
                if entry.record.attention == .seen {
                    Button("Mark as unseen") { actions.markUnseen(key) }
                } else {
                    Button("Mark as seen") { actions.markSeen(key) }
                }
                Button("Open on GitHub") { actions.open(entry.record) }
            }
        } primaryAction: { keys in
            if let key = keys.first, let entry = entries.first(where: { $0.id == key }) {
                actions.open(entry.record)
            }
        }
    }
}

#Preview("Rows") {
    List(PreviewSamples.entries) { entry in
        ItemRow(entry: entry)
    }
    .frame(width: 420, height: 360)
}
