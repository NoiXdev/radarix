import RadarixKit
import SwiftUI

/// A listed record together with its repository, as the layouts show it.
struct ItemEntry: Identifiable, Hashable {
    let record: ItemRecord
    let repo: RepoRef
    var id: ItemKey { record.item.key }
}

/// One watched repository: its attention counts per kind and the entries that pass the filters.
struct RepoSection: Identifiable {
    let repo: RepoRef
    let kindCounts: KindCounts
    let entries: [ItemEntry]
    let failure: SyncFailure?
    var id: RepoID { repo.id }
}

/// The repositories one account owns, ordered like that account's owners list, then by name.
struct AccountSection: Identifiable {
    let login: String
    let repos: [RepoSection]
    var id: String { login }
}

/// What rows, menus and the detail can do. The defaults do nothing, for previews.
struct ItemActions {
    var markSeen: @MainActor (ItemKey) -> Void = { _ in }
    var markUnseen: @MainActor (ItemKey) -> Void = { _ in }
    /// Opens the item on GitHub and marks it seen.
    var open: @MainActor (ItemRecord) -> Void = { _ in }
    var markRepoSeen: @MainActor (RepoID) -> Void = { _ in }
    var openRepo: @MainActor (RepoRef) -> Void = { _ in }
    /// Opens the item's description window, or brings it to the front.
    var showDescription: @MainActor (ItemKey) -> Void = { _ in }
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
    @Environment(\.openWindow) private var openWindow

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
                model.receive(link)
            }
            .onAppear {
                model.mainWindowAppeared()
                navigate()
            }
            .onChange(of: model.navigation) { navigate() }
            .onChange(of: controller.isSignedIn) { navigate() }
    }

    @ViewBuilder private var content: some View {
        let repos = controller.repos
        if !controller.isSignedIn {
            ContentUnavailableView {
                Label("Sign in to see what's new", systemImage: "person.crop.circle.badge.questionmark")
            } description: {
                Text("Radarix watches your GitHub repositories for new and updated pull requests and issues.")
            } actions: {
                Button("Sign in") { openSettings() }
            }
        } else if !repos.isEmpty {
            layout(repos)
                .onChange(of: controller.settings.filter) { filterChanged() }
                .onChange(of: controller.settings.showsBots) { filterChanged() }
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

    @ViewBuilder private func layout(_ repos: [RepoID: RepoState]) -> some View {
        let entries = visibleEntries(repos)
        let sections = accountSections(repos, entries: entries)
        let selected = selection.flatMap { entry(for: $0, in: repos) }
        let showsBotBadges = controller.settings.botDisplay == .badge
        switch controller.settings.layout {
        case .sidebar:
            SidebarLayout(
                accountSections: sections, allEntries: entries, totalKindCounts: controller.kindCounts(in: nil),
                groupsAll: groupsAll,
                sidebarSelection: $sidebarSelection, selection: $selection, selectedEntry: selected,
                scrollTarget: $scrollTarget, showsBotBadges: showsBotBadges, actions: actions
            ) { header }
        case .grouped:
            GroupedListLayout(
                sections: sections.flatMap(\.repos), selection: $selection, selectedEntry: selected,
                scrollTarget: $scrollTarget, showsBotBadges: showsBotBadges, actions: actions
            ) { header }
        }
    }

    private var header: some View {
        VStack(spacing: 0) {
            MainBanners(openSettings: { openSettings() })
            FilterBar(
                filter: filter,
                showsBots: showsBots,
                offersBotsChip: controller.settings.botDisplay == .grouped
            )
            Divider()
        }
        .background(.bar)
    }

    @ToolbarContentBuilder private var syncToolbar: some ToolbarContent {
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
                .disabled(!canRefresh)
            }
        }
    }

    /// Some account's sign-in is still accepted.
    private var canRefresh: Bool {
        controller.sessions.contains { $0.auth == .ok }
    }

    /// The layouts are on screen, so their `onChange` handlers run.
    private var showsLayout: Bool {
        controller.isSignedIn && !controller.repos.isEmpty
    }

    // MARK: Navigation

    /// Applies and consumes `model.navigation`. It waits while no account is loaded yet.
    private func navigate() {
        guard let link = model.navigation, controller.isSignedIn else { return }
        model.navigation = nil
        guard let target = MainNavigation(link, repos: controller.repos, layout: controller.settings.layout)
        else { return }
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
            get: { controller.settings.filter },
            set: { value in controller.updateSettings { $0.filter = value } }
        )
    }

    private var groupsAll: Binding<Bool> {
        Binding(
            get: { controller.settings.groupAllByRepo },
            set: { value in controller.updateSettings { $0.groupAllByRepo = value } }
        )
    }

    /// The Bots chip, only offered while bots form their own group.
    private var showsBots: Binding<Bool> {
        Binding(
            get: { controller.settings.showsBots },
            set: { value in controller.updateSettings { $0.showsBots = value } }
        )
    }

    private var scope: BotScope {
        if controller.settings.botDisplay == .grouped { showsBots.wrappedValue ? .bots : .humans }
        else { ItemFilter.scope(for: controller.settings.botDisplay) }
    }

    /// A filter change ends the pin; a selection the new filter hides is dropped.
    private func filterChanged() {
        pinned = nil
        guard let key = selection, controller.isSignedIn else { return }
        if !currentKeys(controller.repos).contains(key) { selection = nil }
    }

    /// The keys of the list the user currently sees.
    private func currentKeys(_ repos: [RepoID: RepoState]) -> Set<ItemKey> {
        var entries = visibleEntries(repos)
        if controller.settings.layout == .sidebar, case .repo(let id) = sidebarSelection {
            entries = entries.filter { $0.repo.id == id }
        }
        return Set(entries.map(\.id))
    }

    // MARK: Data

    /// Every watched repo's entries that pass the filters, plus the pinned one, in filter order.
    private func visibleEntries(_ repos: [RepoID: RepoState]) -> [ItemEntry] {
        var records = ItemFilter.visible(
            controller.records(in: nil),
            filter: filter.wrappedValue,
            viewers: controller.viewers,
            scope: scope
        )
        if let pinned, !records.contains(where: { $0.item.key == pinned }),
           let record = repos[pinned.repo]?.records[pinned.number] {
            records.append(record)
            records.sort(by: Self.precedes)
        }
        return records.compactMap { record in
            repos[record.item.key.repo].map { ItemEntry(record: record, repo: $0.repo) }
        }
    }

    /// The order of `ItemFilter.visible`: newest `updatedAt` first, then repo id, then number.
    private static func precedes(_ a: ItemRecord, _ b: ItemRecord) -> Bool {
        if a.item.updatedAt != b.item.updatedAt { return a.item.updatedAt > b.item.updatedAt }
        if a.item.key.repo != b.item.key.repo { return a.item.key.repo.rawValue < b.item.key.repo.rawValue }
        return a.item.key.number < b.item.key.number
    }

    /// One section per account in account order, each with the watched repos it owns ordered like
    /// its owners list, then by name. An account that owns no watched repo has an empty section.
    private func accountSections(_ repos: [RepoID: RepoState], entries: [ItemEntry]) -> [AccountSection] {
        let byRepo = Dictionary(grouping: entries, by: \.repo.id)
        let byOwner = Dictionary(grouping: repos.values.map(\.repo)) { controller.owner(of: $0.id)?.accountID }
        return controller.sessions.map { session in
            let owned = byOwner[session.accountID] ?? []
            let ownerOrder = Dictionary(
                session.owners.enumerated().map { ($1.login, $0) }, uniquingKeysWith: { first, _ in first }
            )
            let sections = owned
                .sorted { a, b in
                    let rankA = ownerOrder[a.owner] ?? .max, rankB = ownerOrder[b.owner] ?? .max
                    if rankA != rankB { return rankA < rankB }
                    if a.owner != b.owner { return a.owner.localizedCaseInsensitiveCompare(b.owner) == .orderedAscending }
                    return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
                }
                .map { repo in
                    RepoSection(
                        repo: repo,
                        kindCounts: controller.kindCounts(in: repo.id),
                        entries: byRepo[repo.id] ?? [],
                        failure: session.lastReport?.repoFailures[repo.id]
                    )
                }
            return AccountSection(login: session.login, repos: sections)
        }
    }

    private func entry(for key: ItemKey, in repos: [RepoID: RepoState]) -> ItemEntry? {
        guard let state = repos[key.repo], let record = state.records[key.number] else { return nil }
        return ItemEntry(record: record, repo: state.repo)
    }

    private var actions: ItemActions {
        let controller = controller
        let openURL = openURL
        let openWindow = openWindow
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
            },
            showDescription: { openWindow(id: "description", value: $0) }
        )
    }
}

/// Warnings above the list: sign-in rejected, offline, rate limit (one per affected account, led
/// by its login while there is more than one), repositories that failed to sync (all accounts).
private struct MainBanners: View {
    let openSettings: () -> Void

    @Environment(AppModel.self) private var model

    private var controller: RadarixController { model.controller }

    var body: some View {
        let named = controller.sessions.count > 1
        ForEach(controller.needsReauth, id: \.accountID) { session in
            Banner(systemImage: "exclamationmark.triangle.fill", tint: .orange) {
                if named {
                    Text("\(session.login): sign in again")
                } else {
                    Text("GitHub no longer accepts the sign-in for \(session.login). Sign in again to continue syncing.")
                }
            } action: {
                Button("Sign in again", action: openSettings)
            }
        }
        ForEach(controller.sessions.filter { $0.syncProblem == .offline }, id: \.accountID) { session in
            Banner(systemImage: "wifi.slash", tint: .secondary, login: named ? session.login : nil) {
                Text("Can't reach GitHub. Showing saved data.")
            }
        }
        ForEach(rateLimits) { limit in
            TimelineView(.everyMinute) { context in
                if limit.until > context.date {
                    Banner(systemImage: "hourglass", tint: .yellow, login: named ? limit.login : nil) {
                        Text("GitHub's rate limit is reached. Radarix syncs again after \(Text(limit.until, style: .time)).")
                    }
                }
            }
        }
        let failures = repoFailures
        if !failures.isEmpty {
            Banner(systemImage: "exclamationmark.circle", tint: .secondary) {
                Text("\(failures.count) repositories could not be updated.")
            }
            .help(failureDetails(failures))
        }
    }

    private struct RateLimit: Identifiable {
        let id: AccountID
        let login: String
        let until: Date
    }

    /// Each rate-limited account with its reset, from the owners request or the sync itself.
    private var rateLimits: [RateLimit] {
        controller.sessions.compactMap { session in
            let until: Date? = if case .rateLimited(let until) = session.syncProblem {
                until
            } else {
                session.lastReport?.rateLimitedUntil
            }
            return until.map { RateLimit(id: session.accountID, login: session.login, until: $0) }
        }
    }

    /// The failed repos of every account's last sync.
    private var repoFailures: [RepoID: SyncFailure] {
        controller.sessions.reduce(into: [:]) { result, session in
            result.merge(session.lastReport?.repoFailures ?? [:]) { first, _ in first }
        }
    }

    /// One line per failed repo: its name and what went wrong.
    private func failureDetails(_ failures: [RepoID: SyncFailure]) -> String {
        let repos = controller.repos
        return failures
            .map { id, failure in
                let name = repos[id]?.repo.fullName ?? String(id.rawValue)
                return "\(name): \(AppModel.message(for: failure))"
            }
            .sorted()
            .joined(separator: "\n")
    }
}

/// A full-width strip with an icon, a message led by an optional account login, and an optional button.
private struct Banner<Message: View, Action: View>: View {
    let systemImage: String
    let tint: Color
    var login: String?
    @ViewBuilder let message: Message
    @ViewBuilder let action: Action

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage).foregroundStyle(tint)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                if let login { Text(verbatim: "\(login):").fontWeight(.semibold) }
                message
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            action
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(tint.opacity(0.15))
    }
}

extension Banner where Action == EmptyView {
    init(systemImage: String, tint: Color, login: String? = nil, @ViewBuilder message: () -> Message) {
        self.init(systemImage: systemImage, tint: tint, login: login, message: message, action: { EmptyView() })
    }
}
