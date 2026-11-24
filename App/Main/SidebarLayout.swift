import RadarixKit
import SwiftUI

/// Three columns: "All" and the watched repositories by owner, the filtered items, the selected item.
struct SidebarLayout<Header: View>: View {
    let sections: [RepoSection]
    /// The filtered entries of every repository, in list order.
    let allEntries: [ItemEntry]
    let totalCounts: AttentionCounts
    @Binding var sidebarSelection: SidebarItem?
    @Binding var selection: ItemKey?
    let selectedEntry: ItemEntry?
    let showsBotBadges: Bool
    let actions: ItemActions
    @ViewBuilder let header: Header

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 200, ideal: 240)
        } content: {
            itemList
                .safeAreaInset(edge: .top, spacing: 0) { header }
                .navigationSplitViewColumnWidth(min: 340, ideal: 420)
        } detail: {
            if let selectedEntry {
                ItemDetail(entry: selectedEntry) { actions.open(selectedEntry.record) }
            } else {
                NoItemSelected()
            }
        }
    }

    private var sidebar: some View {
        List(selection: $sidebarSelection) {
            HStack {
                Label("All", systemImage: "tray.full")
                Spacer()
                AttentionBadges(counts: totalCounts)
            }
            .tag(SidebarItem.all)
            ForEach(owners, id: \.self) { owner in
                Section {
                    ForEach(sections.filter { $0.repo.owner == owner }) { section in
                        RepoSidebarRow(section: section)
                            .tag(SidebarItem.repo(section.id))
                            .contextMenu {
                                Button("Mark repository as seen") { actions.markRepoSeen(section.id) }
                                Button("Open on GitHub") { actions.openRepo(section.repo) }
                            }
                    }
                } header: {
                    Text(verbatim: owner)
                }
            }
        }
    }

    /// Owner logins in the order of `sections`.
    private var owners: [String] {
        var seen = Set<String>()
        return sections.map(\.repo.owner).filter { seen.insert($0).inserted }
    }

    private var selectedRepo: RepoID? {
        if case .repo(let id) = sidebarSelection { id } else { nil }
    }

    private var entries: [ItemEntry] {
        guard let selectedRepo else { return allEntries }
        return sections.first { $0.id == selectedRepo }?.entries ?? []
    }

    private var itemList: some View {
        List(selection: $selection) {
            ForEach(entries) { entry in
                ItemRow(entry: entry, showsRepo: selectedRepo == nil, showsBotBadge: showsBotBadges)
                    .tag(entry.id)
            }
        }
        .itemContextMenu(entries: entries, actions: actions)
        .overlay {
            if entries.isEmpty { NoMatchingItems() }
        }
    }
}

/// A watched repository with its counts; dimmed when the filters leave nothing to show.
private struct RepoSidebarRow: View {
    let section: RepoSection

    var body: some View {
        HStack(spacing: 6) {
            Label {
                Text(verbatim: section.repo.name)
            } icon: {
                Image(systemName: section.repo.isPrivate ? "lock" : "book.closed")
            }
            .foregroundStyle(section.entries.isEmpty ? .secondary : .primary)
            if let failure = section.failure {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                    .help(AppModel.message(for: failure))
                    .accessibilityLabel(AppModel.message(for: failure))
            }
            Spacer()
            AttentionBadges(counts: section.counts)
        }
    }
}

/// The list is empty under the current filters.
struct NoMatchingItems: View {
    var body: some View {
        ContentUnavailableView(
            "No items",
            systemImage: "checkmark.circle",
            description: Text("Nothing matches the current filters.")
        )
    }
}

#Preview("Sidebar layout") {
    @Previewable @State var sidebarSelection: SidebarItem? = .all
    @Previewable @State var selection: ItemKey?
    SidebarLayout(
        sections: PreviewSamples.sections,
        allEntries: PreviewSamples.entries,
        totalCounts: ItemFilter.counts(PreviewSamples.records, bots: .badge),
        sidebarSelection: $sidebarSelection,
        selection: $selection,
        selectedEntry: PreviewSamples.entries.first { $0.id == selection },
        showsBotBadges: true,
        actions: ItemActions()
    ) {
        FilterBar(filter: .constant(FilterSet()), showsBots: .constant(false), offersBotsChip: false)
    }
    .frame(width: 1000, height: 560)
}
