import RadarixKit
import SwiftUI

/// Filter chips: attention, assignment and kind, plus Bots while bots form their own group.
struct FilterBar: View {
    @Binding var filter: FilterSet
    @Binding var showsBots: Bool
    let offersBotsChip: Bool

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                Toggle("New", isOn: $filter.new)
                Toggle("Updated", isOn: $filter.updated)
                separator
                Toggle("Unassigned", isOn: $filter.unassigned)
                Toggle("Assigned to me", isOn: $filter.assignedToMe)
                Toggle("Review requested", isOn: $filter.reviewRequested)
                separator
                Toggle("Pull requests", isOn: $filter.pullRequests)
                Toggle("Issues", isOn: $filter.issues)
                if offersBotsChip {
                    separator
                    Toggle(isOn: $showsBots) {
                        Label("Bots", systemImage: "gearshape.2")
                    }
                    .help("Show only items created by bots")
                }
            }
            .toggleStyle(.button)
            .controlSize(.small)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .scrollIndicators(.never)
    }

    private var separator: some View {
        Divider().frame(height: 14)
    }
}

#Preview("Filter bar") {
    @Previewable @State var filter = FilterSet()
    @Previewable @State var showsBots = false
    FilterBar(filter: $filter, showsBots: $showsBots, offersBotsChip: true)
        .frame(width: 720)
}
