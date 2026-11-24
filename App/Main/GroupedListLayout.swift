import RadarixKit
import SwiftUI

/// One list with a section per repository; the selected item shows in the inspector.
struct GroupedListLayout<Header: View>: View {
    let sections: [RepoSection]
    @Binding var selection: ItemKey?
    let selectedEntry: ItemEntry?
    let showsBotBadges: Bool
    let actions: ItemActions
    @ViewBuilder let header: Header

    @State private var showsInspector = true

    /// Sections the filters leave something in.
    private var visibleSections: [RepoSection] { sections.filter { !$0.entries.isEmpty } }

    var body: some View {
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
                        AttentionBadges(counts: section.counts)
                    }
                }
            }
        }
        .itemContextMenu(entries: visibleSections.flatMap(\.entries), actions: actions)
        .overlay {
            if visibleSections.isEmpty { NoMatchingItems() }
        }
        .safeAreaInset(edge: .top, spacing: 0) { header }
        .inspector(isPresented: $showsInspector) {
            Group {
                if let selectedEntry {
                    ItemDetail(entry: selectedEntry) { actions.open(selectedEntry.record) }
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

#Preview("Grouped layout") {
    @Previewable @State var selection: ItemKey?
    GroupedListLayout(
        sections: PreviewSamples.sections,
        selection: $selection,
        selectedEntry: PreviewSamples.entries.first { $0.id == selection },
        showsBotBadges: true,
        actions: ItemActions()
    ) {
        FilterBar(filter: .constant(FilterSet()), showsBots: .constant(false), offersBotsChip: true)
    }
    .frame(width: 900, height: 560)
}
