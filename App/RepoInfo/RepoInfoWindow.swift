import RadarixKit
import SwiftUI

/// One repository's numbers in its own window: description, topics, the current counts and what
/// happened over the last 7, 30 or 90 days. The listing's counts show at once; the rest is fetched
/// when the window opens and whenever the period changes.
struct RepoInfoWindow: View {
    let id: RepoID

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    /// The last answer, kept while a newer one loads or fails.
    @State private var insights: RepoInsights?
    /// The period `insights` was counted over.
    @State private var insightsDays: Int?
    @State private var isLoading = false
    @State private var failure: String?
    /// Bumped by "Try again" to run the fetch once more.
    @State private var attempt = 0

    /// Identifies one load. A period change or a retry cancels the load before it.
    private struct LoadID: Equatable {
        let days: Int
        let attempt: Int
    }

    private var repo: RepoRef? { model.controller.repos[id]?.repo }
    private var days: Int { model.controller.settings.repoInfoPeriodDays }

    var body: some View {
        Group {
            if let repo {
                content(repo)
            } else {
                ContentUnavailableView("Repository not available", systemImage: "questionmark.circle")
            }
        }
        .frame(minWidth: 420, minHeight: 360)
        .navigationTitle(repo?.fullName ?? "")
        .background {
            // Escape closes the window.
            Button("Close") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .opacity(0)
                .accessibilityHidden(true)
        }
        // A deep link arriving while this window is in front goes to the main window.
        .handlesExternalEvents(preferring: [], allowing: [])
        .task(id: LoadID(days: days, attempt: attempt)) { await load() }
    }

    private func content(_ repo: RepoRef) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header(repo)
                numbers
                period
                if let failure {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                        Text(verbatim: failure)
                        Button("Try again") { attempt += 1 }
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Header

    private func header(_ repo: RepoRef) -> some View {
        let stats = model.controller.repoStats(id)
        let description = insights?.description ?? stats?.description
        let language = insights?.language ?? stats?.language
        let facts = [language, insights?.license].compactMap { $0 }
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(verbatim: repo.fullName)
                    .font(.title3.weight(.semibold))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Open on GitHub") {
                    if let url = URL(string: "https://github.com/\(repo.owner)/\(repo.name)") { openURL(url) }
                }
            }
            if let description, !description.isEmpty {
                Text(verbatim: description)
                    .textSelection(.enabled)
            }
            if !facts.isEmpty {
                Text(verbatim: facts.joined(separator: " · "))
                    .foregroundStyle(.secondary)
            }
            if let topics = insights?.topics, !topics.isEmpty {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 60), spacing: 6, alignment: .leading)], alignment: .leading, spacing: 6) {
                    ForEach(topics, id: \.self) { topic in
                        Text(verbatim: topic)
                            .font(.caption)
                            .lineLimit(1)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(.quaternary, in: Capsule())
                    }
                }
            }
        }
    }

    // MARK: Now

    private var numbers: some View {
        let columns = [GridItem(.adaptive(minimum: 130), spacing: 10, alignment: .top)]
        return LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
            if let insights {
                StatTile(symbol: "star", label: "Stars") { count(insights.stars) }
                StatTile(symbol: "tuningfork", label: "Forks") { count(insights.forks) }
                StatTile(symbol: "eye", label: "Watchers") { count(insights.watchers) }
                StatTile(symbol: "exclamationmark.circle", label: "Open issues") { count(insights.openIssues) }
                StatTile(symbol: "arrow.triangle.pull", label: "Open pull requests") { count(insights.openPulls) }
                StatTile(symbol: "shippingbox", label: "Latest release") { release(insights.latestRelease) }
            } else if let stats = model.controller.repoStats(id) {
                StatTile(symbol: "star", label: "Stars") { count(stats.stars) }
                StatTile(symbol: "tuningfork", label: "Forks") { count(stats.forks) }
                StatTile(symbol: "exclamationmark.circle", label: "Open issues & PRs") { count(stats.openIssuesAndPulls) }
            }
        }
    }

    private func count(_ value: Int) -> Text {
        Text(value, format: .number)
    }

    private func release(_ release: Release?) -> Text {
        guard let release else { return Text("No release") }
        if let date = release.publishedAt {
            return Text("\(release.tag), \(Text(date, format: .relative(presentation: .named)))")
        }
        return Text(verbatim: release.tag)
    }

    // MARK: Period

    private var period: some View {
        let controller = model.controller
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("In the last")
                    .font(.headline)
                // Closures, not method references: Swift 6.3 (Xcode 26) crashes in IRGen on a
                // method reference converted to an @isolated(any) setter.
                Picker(
                    "In the last",
                    selection: Binding(
                        get: { controller.settings.repoInfoPeriodDays },
                        set: { value in controller.updateSettings { $0.repoInfoPeriodDays = value } })
                ) {
                    ForEach(AppSettings.repoInfoPeriods, id: \.self) { days in
                        Text("\(days) days").tag(days)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            if let insights, insightsDays == days {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                    periodRow("New stars", symbol: "star", metric: .stars, in: insights)
                    periodRow("New forks", symbol: "tuningfork", metric: .forks, in: insights)
                    periodRow("Opened issues", symbol: "exclamationmark.circle", metric: .openedIssues, in: insights)
                    periodRow("Opened pull requests", symbol: "arrow.triangle.pull", metric: .openedPulls, in: insights)
                    periodRow("Merged pull requests", symbol: "arrow.triangle.merge", metric: .mergedPulls, in: insights)
                }
            } else if isLoading || failure == nil {
                ProgressView().controlSize(.small)
            }
        }
    }

    private func periodRow(
        _ label: LocalizedStringKey, symbol: String, metric: PeriodMetric, in insights: RepoInsights
    ) -> some View {
        GridRow {
            Label(label, systemImage: symbol)
                .foregroundStyle(.secondary)
            if let value = insights.period[metric] {
                // A count cut off at the paging cap reads "500+".
                Text(verbatim: value.atLeast ? "\(value.value.formatted())+" : value.value.formatted())
                    .monospacedDigit()
                    .gridColumnAlignment(.trailing)
            } else {
                Text(verbatim: "–")
                    .foregroundStyle(.secondary)
                    .gridColumnAlignment(.trailing)
            }
        }
    }

    // MARK: Loading

    private func load() async {
        let days = days
        isLoading = true
        failure = nil
        do {
            let result = try await model.controller.insights(for: id, days: days)
            // A result for a period that has since changed must not overwrite the newer load.
            guard !Task.isCancelled else { return }
            insights = result
            insightsDays = days
            isLoading = false
        } catch {
            // Cancelled when the period changes or the window closes; a cancelled request can
            // arrive as a network error.
            guard !Task.isCancelled else { return }
            isLoading = false
            failure = Self.message(for: error)
        }
    }

    private static func message(for error: Error) -> String {
        if let error = error as? GitHubError, case .notFound = error {
            return String(localized: "This repository can't be read with this sign-in.")
        }
        return AppModel.message(for: error)
    }
}

/// One current number: a symbol, a label and the value.
private struct StatTile<Value: View>: View {
    let symbol: String
    let label: LocalizedStringKey
    @ViewBuilder let value: () -> Value

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(label, systemImage: symbol)
                .font(.caption)
                .foregroundStyle(.secondary)
            value()
                .font(.title3.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }
}
