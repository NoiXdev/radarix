import RadarixKit
import SwiftUI

/// Three columns: "All" and the watched repositories by account and owner, the filtered items, the
/// selected item. With one account the sidebar has no account headers.
struct SidebarLayout<Header: View>: View {
    /// One per account, also for an account that owns no watched repo.
    let accountSections: [AccountSection]
    /// The filtered entries of every repository, in list order.
    let allEntries: [ItemEntry]
    let totalKindCounts: KindCounts
    /// "All" lists its items in a section per repository.
    @Binding var groupsAll: Bool
    @Binding var sidebarSelection: SidebarItem?
    @Binding var selection: ItemKey?
    let selectedEntry: ItemEntry?
    /// Scrolled into view, then set back to nil.
    @Binding var scrollTarget: ScrollTarget?
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
                .toolbar {
                    if selectedRepo == nil {
                        ToolbarItem {
                            Toggle(isOn: $groupsAll) {
                                Label("Group by repository", systemImage: "rectangle.grid.1x2")
                            }
                            .help("Group by repository")
                        }
                    }
                }
        } detail: {
            if let selectedEntry {
                ItemDetail(
                    entry: selectedEntry,
                    onOpen: { actions.open(selectedEntry.record) },
                    onShowDescription: { actions.showDescription(selectedEntry.id) }
                )
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
                KindBadges(counts: totalKindCounts)
            }
            .tag(SidebarItem.all)
            if accountSections.count > 1 {
                // One section per account, like the login prefixes of banners and notifications;
                // its owners become plain subheadings.
                ForEach(accountSections) { account in
                    Section {
                        if account.repos.isEmpty {
                            Text("No repositories watched")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .selectionDisabled()
                        }
                        ForEach(Self.owners(of: account.repos), id: \.self) { owner in
                            Text(verbatim: owner)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .selectionDisabled()
                            repoRows(account.repos.filter { $0.repo.owner == owner })
                        }
                    } header: {
                        Text(verbatim: account.login)
                    }
                }
            } else {
                let sections = repoSections
                ForEach(Self.owners(of: sections), id: \.self) { owner in
                    Section {
                        repoRows(sections.filter { $0.repo.owner == owner })
                    } header: {
                        Text(verbatim: owner)
                    }
                }
            }
        }
    }

    private func repoRows(_ sections: [RepoSection]) -> some View {
        ForEach(sections) { section in
            RepoSidebarRow(section: section)
                .tag(SidebarItem.repo(section.id))
                .contextMenu { RepoContextMenu(section: section, actions: actions) }
        }
    }

    /// Every account's repositories, in sidebar order.
    private var repoSections: [RepoSection] { accountSections.flatMap(\.repos) }

    /// Owner logins in the order of `sections`.
    private static func owners(of sections: [RepoSection]) -> [String] {
        var seen = Set<String>()
        return sections.map(\.repo.owner).filter { seen.insert($0).inserted }
    }

    private var selectedRepo: RepoID? {
        if case .repo(let id) = sidebarSelection { id } else { nil }
    }

    private var entries: [ItemEntry] {
        guard let selectedRepo else { return allEntries }
        return repoSections.first { $0.id == selectedRepo }?.entries ?? []
    }

    @ViewBuilder private var itemList: some View {
        if selectedRepo == nil && groupsAll {
            RepoSectionList(
                sections: repoSections, selection: $selection, scrollTarget: $scrollTarget,
                showsBotBadges: showsBotBadges, actions: actions
            )
        } else {
            flatList
        }
    }

    private var flatList: some View {
        ScrollViewReader { proxy in
            List(selection: $selection) {
                ForEach(entries) { entry in
                    ItemRow(entry: entry, showsRepo: selectedRepo == nil, showsBotBadge: showsBotBadges)
                        .tag(entry.id)
                }
            }
            .itemContextMenu(entries: entries, actions: actions)
            .showsDescriptionOnSpace(selection: selection, actions: actions)
            .overlay {
                if entries.isEmpty { NoMatchingItems() }
            }
            .onChange(of: scrollTarget, initial: true) { _, target in
                guard let target else { return }
                if case .item(let key) = target { proxy.scrollTo(key) }
                scrollTarget = nil
            }
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
            if section.isRefreshing { RepoRefreshIndicator() }
            KindBadges(counts: section.kindCounts)
        }
    }
}

/// The context menu of a repository, in the sidebar and on a section header.
struct RepoContextMenu: View {
    let section: RepoSection
    let actions: ItemActions

    var body: some View {
        Button("Mark repository as seen") { actions.markRepoSeen(section.id) }
        Button("Refresh repository") { actions.refreshRepo(section.id) }
            .disabled(section.isRefreshing)
        Button("Repository Info…") { actions.showRepoInfo(section.id) }
        Button("Open on GitHub") { actions.openRepo(section.repo) }
    }
}

/// Shown while a repository is refreshed alone.
struct RepoRefreshIndicator: View {
    var body: some View {
        ProgressView()
            .controlSize(.small)
            .help("Syncing…")
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
        accountSections: PreviewSamples.accountSections,
        allEntries: PreviewSamples.entries,
        totalKindCounts: ItemFilter.kindCounts(PreviewSamples.records, bots: .badge),
        groupsAll: .constant(false),
        sidebarSelection: $sidebarSelection,
        selection: $selection,
        selectedEntry: PreviewSamples.entries.first { $0.id == selection },
        scrollTarget: .constant(nil),
        showsBotBadges: true,
        actions: ItemActions()
    ) {
        FilterBar(filter: .constant(FilterSet()), showsBots: .constant(false), offersBotsChip: false)
    }
    .frame(width: 1000, height: 560)
}

#Preview("Sidebar layout, two accounts") {
    @Previewable @State var sidebarSelection: SidebarItem? = .all
    @Previewable @State var selection: ItemKey?
    SidebarLayout(
        accountSections: PreviewSamples.twoAccountSections,
        allEntries: PreviewSamples.entries,
        totalKindCounts: ItemFilter.kindCounts(PreviewSamples.records, bots: .badge),
        groupsAll: .constant(false),
        sidebarSelection: $sidebarSelection,
        selection: $selection,
        selectedEntry: PreviewSamples.entries.first { $0.id == selection },
        scrollTarget: .constant(nil),
        showsBotBadges: true,
        actions: ItemActions()
    ) {
        FilterBar(filter: .constant(FilterSet()), showsBots: .constant(false), offersBotsChip: false)
    }
    .frame(width: 1000, height: 560)
}
