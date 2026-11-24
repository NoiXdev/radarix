import RadarixKit
import SwiftUI

/// One item's rendered description in its own window, fetched when the window opens.
struct DescriptionWindow: View {
    let key: ItemKey

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    private var entry: ItemEntry? {
        guard let state = model.controller.repos[key.repo], let record = state.records[key.number] else { return nil }
        return ItemEntry(record: record, repo: state.repo)
    }

    var body: some View {
        Group {
            if let entry {
                content(entry)
            } else {
                ContentUnavailableView("Item not available", systemImage: "questionmark.circle")
            }
        }
        .frame(minWidth: 420, minHeight: 300)
        .navigationTitle(title)
        .background {
            // Escape closes the window. Space stays with the web view, which scrolls with it.
            Button("Close") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .opacity(0)
                .accessibilityHidden(true)
        }
        // A deep link arriving while this window is in front goes to the main window.
        .handlesExternalEvents(preferring: [], allowing: [])
        .onAppear { model.controller.markSeen(key) }
    }

    private var title: String {
        if let entry { "\(entry.repo.fullName) #\(key.number)" } else { "#\(key.number)" }
    }

    private func content(_ entry: ItemEntry) -> some View {
        VStack(spacing: 0) {
            header(entry)
            Divider()
            DescriptionContent(key: key)
        }
    }

    private func header(_ entry: ItemEntry) -> some View {
        let item = entry.record.item
        return HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    KindMarker(item: item)
                    Text(verbatim: "\(entry.repo.fullName) #\(item.key.number)")
                    Text(verbatim: "·")
                    Text(StatusText.label(for: item))
                }
                .foregroundStyle(.secondary)
                Text(verbatim: item.title)
                    .font(.title3.weight(.semibold))
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 6) {
                Button("Open on GitHub") { openURL(item.url) }
                AssignButton(key: item.key)
            }
        }
        .padding(16)
    }
}
