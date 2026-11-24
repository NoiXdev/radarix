import RadarixKit
import SwiftUI

/// One item's rendered description, fetched when it appears and whenever `key` changes.
/// While it loads, and when it fails, the stored excerpt stands in. Shared by the description
/// window and the inspector. It does not mark the item seen: its host does.
struct DescriptionContent: View {
    let key: ItemKey

    @Environment(AppModel.self) private var model

    @State private var phase: Phase = .loading
    /// Bumped by "Try again" to run the fetch once more.
    @State private var attempt = 0

    private enum Phase {
        case loading
        /// Nil: the item has no description.
        case loaded(String?)
        case failed(String)
    }

    /// Identifies one load. A new selection or a retry cancels the load before it.
    private struct LoadID: Equatable {
        let key: ItemKey
        let attempt: Int
    }

    private var entry: ItemEntry? {
        guard let state = model.controller.repos[key.repo], let record = state.records[key.number] else { return nil }
        return ItemEntry(record: record, repo: state.repo)
    }

    var body: some View {
        Group {
            if let entry {
                switch phase {
                case .loaded(let html?):
                    DescriptionWebView(
                        html: DescriptionPage.html(body: html), baseURL: DescriptionPage.baseURL(for: entry.repo),
                        itemURL: entry.record.item.url)
                case .loaded(nil):
                    Text("No description.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .loading:
                    excerpt(entry) {
                        ProgressView().controlSize(.small)
                    }
                case .failed(let reason):
                    excerpt(entry) {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                            Text("Couldn't load the description.")
                                .help(reason)
                            Button("Try again") { attempt += 1 }
                        }
                    }
                }
            }
        }
        .task(id: LoadID(key: key, attempt: attempt)) { await load() }
    }

    /// The stored excerpt as plain text, under a status line.
    private func excerpt(_ entry: ItemEntry, @ViewBuilder status: () -> some View) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                status()
                if !entry.record.item.bodyExcerpt.isEmpty {
                    Text(verbatim: entry.record.item.bodyExcerpt)
                        .textSelection(.enabled)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func load() async {
        guard entry != nil else { return }
        phase = .loading
        do {
            let html = try await model.controller.renderedDescription(of: key)
            // A result for a selection that has since changed must not overwrite the new phase.
            guard !Task.isCancelled else { return }
            phase = .loaded(html)
        } catch {
            // Cancelled when the selection changes or the view goes away; a cancelled request
            // can arrive as a network error.
            guard !Task.isCancelled else { return }
            phase = .failed(AppModel.message(for: error))
        }
    }
}
