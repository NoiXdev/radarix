import RadarixKit
import SwiftUI

/// One item's rendered description in its own window, fetched when the window opens.
/// While it loads, and when it fails, the stored excerpt stands in.
struct DescriptionWindow: View {
    let key: ItemKey

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @State private var phase: Phase = .loading
    /// Bumped by "Try again" to run the fetch once more.
    @State private var attempt = 0

    private enum Phase {
        case loading
        /// Nil: the item has no description.
        case loaded(String?)
        case failed(String)
    }

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
        .task(id: attempt) { await load() }
    }

    private var title: String {
        if let entry { "\(entry.repo.fullName) #\(key.number)" } else { "#\(key.number)" }
    }

    private func content(_ entry: ItemEntry) -> some View {
        VStack(spacing: 0) {
            header(entry)
            Divider()
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
            phase = .loaded(try await model.controller.renderedDescription(of: key))
        } catch {
            // Cancelled when the window closes; a cancelled request can arrive as a network error.
            guard !Task.isCancelled else { return }
            phase = .failed(AppModel.message(for: error))
        }
    }
}
