import RadarixKit
import SwiftUI

/// A listed record together with its repository, as the layouts show it.
struct ItemEntry: Identifiable, Hashable {
    let record: ItemRecord
    let repo: RepoRef
    var id: ItemKey { record.item.key }
}

/// One watched repository: its attention counts and the entries that pass the filters.
struct RepoSection: Identifiable {
    let repo: RepoRef
    let counts: AttentionCounts
    let entries: [ItemEntry]
    let failure: SyncFailure?
    var id: RepoID { repo.id }
}

/// What rows, menus and the detail can do. The defaults do nothing, for previews.
struct ItemActions {
    var markSeen: @MainActor (ItemKey) -> Void = { _ in }
    var markUnseen: @MainActor (ItemKey) -> Void = { _ in }
    /// Opens the item on GitHub and marks it seen.
    var open: @MainActor (ItemRecord) -> Void = { _ in }
    var markRepoSeen: @MainActor (RepoID) -> Void = { _ in }
    var openRepo: @MainActor (RepoRef) -> Void = { _ in }
}

/// The sidebar's choice: every watched repository, or one.
enum SidebarItem: Hashable {
    case all, repo(RepoID)
}

/// The main window: picks the layout, holds the window's filter and selection state.
struct MainWindow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openURL) private var openURL

    /// JSON-encoded `FilterSet`.
    @SceneStorage("main.filter") private var storedFilter = ""
    /// The Bots chip, only offered while bots form their own group.
    @SceneStorage("main.showsBots") private var showsBots = false
    @State private var sidebarSelection: SidebarItem? = .all
    @State private var selection: ItemKey?
    /// The selected key stays listed although the filter would hide it, until selection or filter change.
    @State private var pinned: ItemKey?
    @State private var scrollTarget: ScrollTarget?
    /// A deep link set the sidebar along with the selection; that change must not drop them.
    @State private var navigationSetSidebar = false

    private var controller: RadarixController { model.controller }

    var body: some View {
        content
            .navigationTitle("Radarix")
            .toolbar { syncToolbar }
            .frame(minWidth: 720, minHeight: 420)
            // An open main window takes the link; the window group opens a new one only when none is open.
            .handlesExternalEvents(preferring: [DeepLink.scheme], allowing: [DeepLink.scheme])
            .onOpenURL { url in
                guard let link = DeepLink(url: url) else { return }
                NSApp.activate()
                model.navigation = link
            }
            .onAppear {
                model.mainWindowAppeared()
                navigate()
            }
            .onChange(of: model.navigation) { navigate() }
            .onChange(of: controller.account == nil) { navigate() }
    }

    @ViewBuilder private var content: some View {
        if case .signedOut = controller.auth {
            ContentUnavailableView {
                Label("Sign in to see what's new", systemImage: "person.crop.circle.badge.questionmark")
            } description: {
                Text("Radarix watches your GitHub repositories for new and updated pull requests and issues.")
            } actions: {
                Button("Sign in") { openSettings() }
            }
        } else if let account = controller.account, !account.repos.isEmpty {
            layout(account)
                .onChange(of: storedFilter) { filterChanged() }
                .onChange(of: showsBots) { filterChanged() }
                .onChange(of: sidebarSelection) {
                    if navigationSetSidebar { navigationSetSidebar = false } else { filterChanged() }
                }
                .onChange(of: controller.settings.botDisplay) { filterChanged() }
                .onChange(of: selection) { _, key in
                    pinned = key
                    if let key { controller.markSeen(key) }
                }
        } else {
            Group {
                if controller.isSyncing {
                    ProgressView("Loading repositories…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ContentUnavailableView {
                        Label("No repositories watched", systemImage: "folder.badge.questionmark")
                    } description: {
                        Text("Choose the repositories Radarix should watch.")
                    } actions: {
                        Button("Choose repositories") { openSettings() }
                    }
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) { MainBanners(openSettings: { openSettings() }) }
        }
    }

    @ViewBuilder private func layout(_ account: AccountData) -> some View {
        let entries = visibleEntries(account)
        let sections = repoSections(account, entries: entries)
        let selected = selection.flatMap { entry(for: $0, in: account) }
        let showsBotBadges = controller.settings.botDisplay == .badge
        switch controller.settings.layout {
        case .sidebar:
            SidebarLayout(
                sections: sections, allEntries: entries, totalCounts: controller.counts(in: nil),
                sidebarSelection: $sidebarSelection, selection: $selection, selectedEntry: selected,
                scrollTarget: $scrollTarget, showsBotBadges: showsBotBadges, actions: actions
            ) { header }
        case .grouped:
            GroupedListLayout(
                sections: sections, selection: $selection, selectedEntry: selected,
                scrollTarget: $scrollTarget, showsBotBadges: showsBotBadges, actions: actions
            ) { header }
        }
    }

    private var header: some View {
        VStack(spacing: 0) {
            MainBanners(openSettings: { openSettings() })
            FilterBar(
                filter: filter,
                showsBots: $showsBots,
                offersBotsChip: controller.settings.botDisplay == .grouped
            )
            Divider()
        }
        .background(.bar)
    }

    @ToolbarContentBuilder private var syncToolbar: some ToolbarContent {
        ToolbarItem {
            if let lastSyncAt = controller.lastSyncAt {
                TimelineView(.everyMinute) { _ in
                    Text("Synced \(Text(lastSyncAt, format: .relative(presentation: .named)))")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        }
        ToolbarItem {
            if controller.isSyncing {
                ProgressView()
                    .controlSize(.small)
                    .help("Syncing…")
            } else {
                Button {
                    Task { await controller.refresh() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .help("Refresh")
                .disabled(!isSignedIn)
            }
        }
    }

    private var isSignedIn: Bool {
        if case .signedIn = controller.auth { true } else { false }
    }

    /// The layouts are on screen, so their `onChange` handlers run.
    private var showsLayout: Bool {
        if case .signedOut = controller.auth { return false }
        return controller.account.map { !$0.repos.isEmpty } ?? false
    }

    // MARK: Navigation

    /// Applies and consumes `model.navigation`. It waits while no account is loaded yet.
    private func navigate() {
        guard let link = model.navigation, let account = controller.account else { return }
        model.navigation = nil
        guard let target = MainNavigation(link, in: account, layout: controller.settings.layout) else { return }
        if let sidebar = target.sidebar, sidebar != sidebarSelection {
            navigationSetSidebar = showsLayout
            sidebarSelection = sidebar
        }
        if !target.keepsSelection {
            // Pinned, the item stays listed although the filter would hide it. Selecting marks it seen.
            pinned = target.selection
            selection = target.selection
        }
        scrollTarget = target.scroll
    }

    // MARK: Filter state

    private var filter: Binding<FilterSet> {
        Binding(
            get: { (try? JSONDecoder().decode(FilterSet.self, from: Data(storedFilter.utf8))) ?? FilterSet() },
            set: { newValue in
                guard let data = try? JSONEncoder().encode(newValue) else { return }
                storedFilter = String(decoding: data, as: UTF8.self)
            }
        )
    }

    private var scope: BotScope {
        if controller.settings.botDisplay == .grouped { showsBots ? .bots : .humans }
        else { ItemFilter.scope(for: controller.settings.botDisplay) }
    }

    /// A filter change ends the pin; a selection the new filter hides is dropped.
    private func filterChanged() {
        pinned = nil
        guard let key = selection, let account = controller.account else { return }
        if !currentKeys(account).contains(key) { selection = nil }
    }

    /// The keys of the list the user currently sees.
    private func currentKeys(_ account: AccountData) -> Set<ItemKey> {
        var entries = visibleEntries(account)
        if controller.settings.layout == .sidebar, case .repo(let id) = sidebarSelection {
            entries = entries.filter { $0.repo.id == id }
        }
        return Set(entries.map(\.id))
    }

    // MARK: Data

    /// Every watched repo's entries that pass the filters, plus the pinned one, in filter order.
    private func visibleEntries(_ account: AccountData) -> [ItemEntry] {
        var records = ItemFilter.visible(
            controller.records(in: nil),
            filter: filter.wrappedValue,
            viewer: controller.account?.login ?? "",
            scope: scope
        )
        if let pinned, !records.contains(where: { $0.item.key == pinned }),
           let record = account.repos[pinned.repo]?.records[pinned.number] {
            records.append(record)
            records.sort(by: Self.precedes)
        }
        return records.compactMap { record in
            account.repos[record.item.key.repo].map { ItemEntry(record: record, repo: $0.repo) }
        }
    }

    /// The order of `ItemFilter.visible`: newest `updatedAt` first, then repo id, then number.
    private static func precedes(_ a: ItemRecord, _ b: ItemRecord) -> Bool {
        if a.item.updatedAt != b.item.updatedAt { return a.item.updatedAt > b.item.updatedAt }
        if a.item.key.repo != b.item.key.repo { return a.item.key.repo.rawValue < b.item.key.repo.rawValue }
        return a.item.key.number < b.item.key.number
    }

    /// Watched repos ordered like the owners list, then by name.
    private func repoSections(_ account: AccountData, entries: [ItemEntry]) -> [RepoSection] {
        let byRepo = Dictionary(grouping: entries, by: \.repo.id)
        let ownerOrder = Dictionary(
            controller.owners.enumerated().map { ($1.login, $0) }, uniquingKeysWith: { first, _ in first }
        )
        return account.repos.values
            .map(\.repo)
            .sorted { a, b in
                let rankA = ownerOrder[a.owner] ?? .max, rankB = ownerOrder[b.owner] ?? .max
                if rankA != rankB { return rankA < rankB }
                if a.owner != b.owner { return a.owner.localizedCaseInsensitiveCompare(b.owner) == .orderedAscending }
                return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
            .map { repo in
                RepoSection(
                    repo: repo,
                    counts: controller.counts(in: repo.id),
                    entries: byRepo[repo.id] ?? [],
                    failure: controller.lastReport?.repoFailures[repo.id]
                )
            }
    }

    private func entry(for key: ItemKey, in account: AccountData) -> ItemEntry? {
        guard let state = account.repos[key.repo], let record = state.records[key.number] else { return nil }
        return ItemEntry(record: record, repo: state.repo)
    }

    private var actions: ItemActions {
        let controller = controller
        let openURL = openURL
        return ItemActions(
            markSeen: { controller.markSeen($0) },
            markUnseen: { controller.markUnseen($0) },
            open: { record in
                openURL(record.item.url)
                controller.markSeen(record.item.key)
            },
            markRepoSeen: { controller.markRepoSeen($0) },
            openRepo: { repo in
                if let url = URL(string: "https://github.com/\(repo.owner)/\(repo.name)") { openURL(url) }
            }
        )
    }
}

/// Warnings above the list: sign-in rejected, offline, rate limit, repositories that failed to sync.
private struct MainBanners: View {
    let openSettings: () -> Void

    @Environment(AppModel.self) private var model

    private var controller: RadarixController { model.controller }

    var body: some View {
        if case .needsReauth(let login) = controller.auth {
            Banner(systemImage: "exclamationmark.triangle.fill", tint: .orange) {
                Text("GitHub no longer accepts the sign-in for \(login). Sign in again to continue syncing.")
            } action: {
                Button("Sign in again", action: openSettings)
            }
        }
        if controller.syncProblem == .offline {
            Banner(systemImage: "wifi.slash", tint: .secondary) {
                Text("Can't reach GitHub. Showing saved data.")
            }
        }
        if let until = rateLimitedUntil {
            TimelineView(.everyMinute) { context in
                if until > context.date {
                    Banner(systemImage: "hourglass", tint: .yellow) {
                        Text("GitHub's rate limit is reached. Radarix syncs again after \(Text(until, style: .time)).")
                    }
                }
            }
        }
        if let failures = controller.lastReport?.repoFailures, !failures.isEmpty {
            Banner(systemImage: "exclamationmark.circle", tint: .secondary) {
                Text("\(failures.count) repositories could not be updated.")
            }
            .help(failureDetails(failures))
        }
    }

    /// From the owners request or the sync itself.
    private var rateLimitedUntil: Date? {
        if case .rateLimited(let until) = controller.syncProblem { return until }
        return controller.lastReport?.rateLimitedUntil
    }

    /// One line per failed repo: its name and what went wrong.
    private func failureDetails(_ failures: [RepoID: SyncFailure]) -> String {
        failures
            .map { id, failure in
                let name = controller.account?.repos[id]?.repo.fullName ?? String(id.rawValue)
                return "\(name): \(AppModel.message(for: failure))"
            }
            .sorted()
            .joined(separator: "\n")
    }
}

/// A full-width strip with an icon, a message and an optional button.
private struct Banner<Message: View, Action: View>: View {
    let systemImage: String
    let tint: Color
    @ViewBuilder let message: Message
    @ViewBuilder let action: Action

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage).foregroundStyle(tint)
            message.frame(maxWidth: .infinity, alignment: .leading)
            action
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(tint.opacity(0.15))
    }
}

extension Banner where Action == EmptyView {
    init(systemImage: String, tint: Color, @ViewBuilder message: () -> Message) {
        self.init(systemImage: systemImage, tint: tint, message: message, action: { EmptyView() })
    }
}
