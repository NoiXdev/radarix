import RadarixKit
import SwiftUI

struct RepositorySettings: View {
    @Environment(AppModel.self) private var model
    @State private var search = ""

    private var controller: RadarixController { model.controller }

    var body: some View {
        if controller.sessions.isEmpty {
            ContentUnavailableView("Sign in to choose repositories.", systemImage: "person.crop.circle.badge.questionmark")
        } else {
            Form {
                Section {
                    TextField("Search repositories", text: $search, prompt: Text("Search repositories"))
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                }
                // One account looks as before: no account header.
                let showsAccounts = controller.sessions.count > 1
                ForEach(controller.sessions, id: \.accountID) { session in
                    AccountRepositories(session: session, showsHeader: showsAccounts, search: search)
                }
            }
            .formStyle(.grouped)
        }
    }
}

/// One account's watch settings: its archived toggle, then its owners.
private struct AccountRepositories: View {
    let session: AccountSession
    let showsHeader: Bool
    let search: String

    @Environment(AppModel.self) private var model

    private var controller: RadarixController { model.controller }

    var body: some View {
        if showsHeader {
            Section {
                archivedToggle
            } header: {
                Text(verbatim: session.login)
            }
        } else {
            Section { archivedToggle }
        }
        if session.owners.isEmpty {
            Section {
                Group {
                    if session.isSyncing {
                        Text("Loading accounts and organizations…")
                    } else {
                        Text("No accounts or organizations found.")
                    }
                }
                .foregroundStyle(.secondary)
            }
        }
        ForEach(session.owners, id: \.login) { owner in
            OwnerSection(session: session, owner: owner, watch: session.account.watch, search: search)
        }
    }

    private var archivedToggle: some View {
        HStack {
            Toggle("Show archived repositories", isOn: Binding(
                get: { session.account.watch.showArchived },
                set: { controller.setShowArchived($0, in: session.accountID) }
            ))
            if session.isSyncing {
                Spacer()
                ProgressView().controlSize(.small)
            }
        }
    }
}

/// One owner: its mode, an access warning and its repositories.
private struct OwnerSection: View {
    let session: AccountSession
    let owner: OwnerRef
    let watch: WatchConfig
    let search: String

    @Environment(AppModel.self) private var model

    private enum Choice: Hashable { case off, all, selected }

    private var controller: RadarixController { model.controller }
    private var mode: OwnerMode { watch.owners[owner.login] ?? .off }

    var body: some View {
        Section {
            Picker(selection: choice) {
                Text("Off").tag(Choice.off)
                Text("All").tag(Choice.all)
                Text("Only selected").tag(Choice.selected)
            } label: {
                Label(owner.login, systemImage: owner.kind == .organization ? "building.2" : "person")
            }
            if let issue = session.lastReport?.ownerIssues[owner.login] {
                VStack(alignment: .leading, spacing: 4) {
                    Label(AppModel.message(for: issue), systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Link("Grant access on GitHub", destination: model.grantAccessURL(for: session))
                }
            }
            repositories
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                if case .all = mode {
                    Text("New repositories are watched automatically. Forks are not included. Uncheck a repository to exclude it.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                if session.credentialKind == .oauth, owner.kind == .organization,
                   session.lastReport?.ownerIssues[owner.login] == nil {
                    Link("Missing repositories? Grant access on GitHub", destination: model.grantAccessURL(for: session))
                        .font(.footnote)
                }
            }
        }
    }

    @ViewBuilder private var repositories: some View {
        switch mode {
        case .off:
            EmptyView()
        case .all(let excluded):
            rows(of: { !$0.isFork }) { repo in
                Binding(
                    get: { !excluded.contains(repo.id) },
                    set: { on in
                        controller.setOwnerMode(.all(excluded: on ? excluded.subtracting([repo.id]) : excluded.union([repo.id])), for: owner.login, in: session.accountID)
                    }
                )
            }
        case .selected(let ids):
            rows(of: { _ in true }) { repo in
                Binding(
                    get: { ids.contains(repo.id) },
                    set: { on in
                        controller.setOwnerMode(.selected(on ? ids.union([repo.id]) : ids.subtracting([repo.id])), for: owner.login, in: session.accountID)
                    }
                )
            }
        }
    }

    /// The rows of the repos the mode lists that match the search, or a note that none matches.
    @ViewBuilder private func rows(
        of listed: (RepoRef) -> Bool, isWatched: @escaping (RepoRef) -> Binding<Bool>
    ) -> some View {
        if let repos = available {
            let shown = repos.filter { listed($0) && matchesSearch($0) }
            if shown.isEmpty, !query.isEmpty {
                Text("No matching repositories").foregroundStyle(.secondary)
            } else {
                ForEach(shown, id: \.id) { repo in
                    RepoRow(
                        repo: repo,
                        isWatched: isWatched(repo),
                        notifications: notifications(for: repo),
                        watchedVia: watchedVia(repo)
                    )
                }
            }
        } else {
            loading
        }
    }

    /// The login of another account that syncs `repo`; this account's tick then has no effect.
    private func watchedVia(_ repo: RepoRef) -> String? {
        guard let id = controller.ownership[repo.id], id != session.accountID else { return nil }
        return controller.session(for: id)?.login
    }

    private var loading: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Loading repositories…").foregroundStyle(.secondary)
        }
    }

    /// The owner's repos as the watch config sees them: archived ones only when shown, sorted by name.
    private var available: [RepoRef]? {
        session.account.available[owner.login].map { repos in
            repos
                .filter { watch.showArchived || !$0.isArchived }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
    }

    private var query: String {
        search.trimmingCharacters(in: .whitespaces)
    }

    private func matchesSearch(_ repo: RepoRef) -> Bool {
        query.isEmpty || repo.name.localizedCaseInsensitiveContains(query)
            || repo.fullName.localizedCaseInsensitiveContains(query)
    }

    private var choice: Binding<Choice> {
        Binding(
            get: {
                switch mode {
                case .off: .off
                case .all: .all
                case .selected: .selected
                }
            },
            set: { newValue in
                let newMode: OwnerMode = switch newValue {
                case .off: .off
                case .all: .all(excluded: [])
                case .selected: .selected([])
                }
                if newMode != mode { controller.setOwnerMode(newMode, for: owner.login, in: session.accountID) }
            }
        )
    }

    private func notifications(for repo: RepoRef) -> Binding<Bool> {
        Binding(
            get: { !watch.notificationsOff.contains(repo.id) },
            set: { controller.setNotifications($0, for: repo.id, in: session.accountID) }
        )
    }
}

/// A repository with its watch checkbox and, while watched, a notification bell. A repo another
/// account syncs shows as watched, cannot be changed here, and names that account instead.
private struct RepoRow: View {
    let repo: RepoRef
    @Binding var isWatched: Bool
    @Binding var notifications: Bool
    let watchedVia: String?

    var body: some View {
        HStack {
            Toggle(isOn: watchedVia == nil ? $isWatched : .constant(true)) {
                HStack(spacing: 6) {
                    Text(verbatim: repo.name)
                    if repo.isPrivate {
                        Image(systemName: "lock.fill")
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Private")
                    }
                    if repo.isFork { marker("Fork") }
                    if repo.isArchived { marker("Archived") }
                }
            }
            .toggleStyle(.checkbox)
            .disabled(watchedVia != nil)
            Spacer()
            if let watchedVia {
                Text("Watched via \(watchedVia)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if isWatched {
                Toggle(isOn: $notifications) {
                    Label("Notifications", systemImage: notifications ? "bell.fill" : "bell.slash")
                }
                .toggleStyle(.button)
                .buttonStyle(.borderless)
                .labelStyle(.iconOnly)
                .help(notifications ? LocalizedStringKey("Notifications are on") : LocalizedStringKey("Notifications are off"))
            }
        }
    }

    private func marker(_ text: LocalizedStringKey) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary)
    }
}
