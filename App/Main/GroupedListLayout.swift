import RadarixKit
import SwiftUI

/// One list with a section per repository; the selected item shows in the inspector.
struct GroupedListLayout<Header: View>: View {
    let sections: [RepoSection]
    @Binding var selection: ItemKey?
    let selectedEntry: ItemEntry?
    /// Scrolled into view, then set back to nil.
    @Binding var scrollTarget: ScrollTarget?
    let showsBotBadges: Bool
    let actions: ItemActions
    @ViewBuilder let header: Header

    @State private var showsInspector = true

    var body: some View {
        RepoSectionList(
            sections: sections, selection: $selection, scrollTarget: $scrollTarget,
            showsBotBadges: showsBotBadges, actions: actions
        )
        .safeAreaInset(edge: .top, spacing: 0) { header }
        .inspector(isPresented: $showsInspector) {
            Group {
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
            .inspectorColumnWidth(min: 280, ideal: 340)
        }
        .toolbar {
            ToolbarItem {
                Toggle(isOn: $showsInspector) {
                    Label("Inspector", systemImage: "sidebar.trailing")
                }
                .help("Show or hide the inspector")
            }
        }
    }
}

/// A list with a section per repository. Sections the filters leave empty are hidden.
struct RepoSectionList: View {
    let sections: [RepoSection]
    @Binding var selection: ItemKey?
    /// Scrolled into view, then set back to nil.
    @Binding var scrollTarget: ScrollTarget?
    let showsBotBadges: Bool
    let actions: ItemActions

    /// Sections the filters leave something in.
    private var visibleSections: [RepoSection] { sections.filter { !$0.entries.isEmpty } }

    var body: some View {
        ScrollViewReader { proxy in
            list
                .onChange(of: scrollTarget, initial: true) { _, target in
                    guard let target else { return }
                    switch target {
                    case .item(let key):
                        proxy.scrollTo(key)
                    case .repo(let id):
                        // The section's first row at the top brings its header into view.
                        if let first = visibleSections.first(where: { $0.id == id })?.entries.first {
                            proxy.scrollTo(first.id, anchor: .top)
                        }
                    }
                    scrollTarget = nil
                }
        }
    }

    private var list: some View {
        List(selection: $selection) {
            ForEach(visibleSections) { section in
                Section {
                    ForEach(section.entries) { entry in
                        ItemRow(entry: entry, showsRepo: false, showsBotBadge: showsBotBadges)
                            .tag(entry.id)
                    }
                } header: {
                    HStack {
                        Text(verbatim: "\(section.repo.owner) / \(section.repo.name)")
                        Spacer()
                        if section.isRefreshing { RepoRefreshIndicator() }
                        KindBadges(counts: section.kindCounts)
                    }
                    .contentShape(Rectangle())
                    .contextMenu { RepoContextMenu(section: section, actions: actions) }
                }
            }
        }
        .itemContextMenu(entries: visibleSections.flatMap(\.entries), actions: actions)
        .showsDescriptionOnSpace(selection: selection, actions: actions)
        .overlay {
            if visibleSections.isEmpty { NoMatchingItems() }
        }
    }
}

#Preview("Grouped layout") {
    @Previewable @State var selection: ItemKey?
    GroupedListLayout(
        sections: PreviewSamples.sections,
        selection: $selection,
        selectedEntry: PreviewSamples.entries.first { $0.id == selection },
        scrollTarget: .constant(nil),
        showsBotBadges: true,
        actions: ItemActions()
    ) {
        FilterBar(filter: .constant(FilterSet()), showsBots: .constant(false), offersBotsChip: true)
    }
    .frame(width: 900, height: 560)
}
