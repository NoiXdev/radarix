import RadarixKit
import SwiftUI

/// Everything Radarix knows about one item, with ways to read its description and open it on GitHub.
struct ItemDetail: View {
    let entry: ItemEntry
    let onOpen: () -> Void
    let onShowDescription: () -> Void

    private var item: Item { entry.record.item }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 8) {
                    row("Status") { Text(StatusText.label(for: item)) }
                    row("Author") { Text(verbatim: item.author.botDisplayName ?? item.author.login) }
                    if !item.labels.isEmpty {
                        row("Labels") { LabelList(item: item) }
                    }
                    row("Assignees") { people(item.assignees) }
                    if item.kind == .pullRequest {
                        row("Requested reviewers") { people(item.requestedReviewers) }
                    }
                    row("Updated") { RelativeTime(date: item.updatedAt) }
                }
                Divider()
                HStack {
                    Button("Show description", action: onShowDescription)
                    Button("Open on GitHub", action: onOpen)
                }
                // A failure belongs to its item: another selection starts clean.
                AssignButton(key: item.key).id(item.key)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                KindMarker(item: item)
                Text(verbatim: entry.repo.fullName)
                Text(verbatim: "#\(item.key.number)")
            }
            .foregroundStyle(.secondary)
            Text(verbatim: item.title)
                .font(.title2.weight(.semibold))
                .textSelection(.enabled)
        }
    }

    private func row(_ title: LocalizedStringKey, @ViewBuilder value: () -> some View) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            value()
        }
    }

    @ViewBuilder private func people(_ logins: [String]) -> some View {
        if logins.isEmpty {
            Text("Nobody").foregroundStyle(.secondary)
        } else {
            Text(verbatim: logins.joined(separator: ", "))
        }
    }
}

/// GitHub labels as tinted capsules.
private struct LabelList: View {
    /// The item, not its labels: `Label` alone would name SwiftUI's view.
    let item: Item

    var body: some View {
        // Wraps by falling back to a vertical stack when a single line does not fit.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 4) { chips }
            VStack(alignment: .leading, spacing: 4) { chips }
        }
    }

    private var chips: some View {
        ForEach(item.labels, id: \.name) { label in
            let color = label.colorHex.flatMap { Color(hex: $0) } ?? .secondary
            Text(verbatim: label.name)
                .font(.caption)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(color.opacity(0.25), in: Capsule())
                .overlay(Capsule().strokeBorder(color.opacity(0.6)))
        }
    }
}

private extension Color {
    /// A six-digit hex value as GitHub sends it, without `#`.
    init?(hex: String) {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}

/// Shown while nothing is selected.
struct NoItemSelected: View {
    var body: some View {
        ContentUnavailableView("No item selected", systemImage: "doc.text.magnifyingglass")
    }
}

#Preview("Detail") {
    ItemDetail(entry: PreviewSamples.entries[1], onOpen: {}, onShowDescription: {})
        .frame(width: 380, height: 460)
}
