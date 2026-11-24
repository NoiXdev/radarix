import RadarixKit
import SwiftUI

struct RepositorySettings: View {
    @Environment(AppModel.self) private var model

    private var controller: RadarixController { model.controller }

    var body: some View {
        if let account = controller.account {
            Form {
                Section {
                    HStack {
                        Toggle("Show archived repositories", isOn: Binding(
                            get: { account.watch.showArchived },
                            set: { controller.setShowArchived($0) }
                        ))
                        if controller.isSyncing {
                            Spacer()
                            ProgressView().controlSize(.small)
                        }
                    }
                }
                if controller.owners.isEmpty {
                    Section {
                        Group {
                            if controller.isSyncing {
                                Text("Loading accounts and organizations…")
                            } else {
                                Text("No accounts or organizations found.")
                            }
                        }
                        .foregroundStyle(.secondary)
                    }
                }
                ForEach(controller.owners, id: \.login) { owner in
                    OwnerSection(owner: owner, watch: account.watch)
                }
            }
            .formStyle(.grouped)
        } else {
            ContentUnavailableView("Sign in to choose repositories.", systemImage: "person.crop.circle.badge.questionmark")
        }
    }
}

/// One owner: its mode, an access warning and its repositories.
private struct OwnerSection: View {
    let owner: OwnerRef
    let watch: WatchConfig

    @Environment(AppModel.self) private var model
    @State private var search = ""

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
            if let issue = controller.lastReport?.ownerIssues[owner.login] {
                VStack(alignment: .leading, spacing: 4) {
                    Label(AppModel.message(for: issue), systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Link("Grant access on GitHub", destination: model.grantAccessURL)
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
                if controller.credentialKind == .oauth, owner.kind == .organization {
                    Link("Missing repositories? Grant access on GitHub", destination: model.grantAccessURL)
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
            if let repos = available {
                ForEach(repos.filter { !$0.isFork }, id: \.id) { repo in
                    RepoRow(repo: repo, isWatched: Binding(
                        get: { !excluded.contains(repo.id) },
                        set: { on in
                            controller.setOwnerMode(.all(excluded: on ? excluded.subtracting([repo.id]) : excluded.union([repo.id])), for: owner.login)
                        }
                    ), notifications: notifications(for: repo))
                }
            } else {
                loading
            }
        case .selected(let ids):
            if let repos = available {
                TextField("Search repositories", text: $search)
                ForEach(repos.filter(matchesSearch), id: \.id) { repo in
                    RepoRow(repo: repo, isWatched: Binding(
                        get: { ids.contains(repo.id) },
                        set: { on in
                            controller.setOwnerMode(.selected(on ? ids.union([repo.id]) : ids.subtracting([repo.id])), for: owner.login)
                        }
                    ), notifications: notifications(for: repo))
                }
            } else {
                loading
            }
        }
    }

    private var loading: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Loading repositories…").foregroundStyle(.secondary)
        }
    }

    /// The owner's repos as the watch config sees them: archived ones only when shown, sorted by name.
    private var available: [RepoRef]? {
        controller.availableRepos[owner.login].map { repos in
            repos
                .filter { watch.showArchived || !$0.isArchived }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
    }

    private func matchesSearch(_ repo: RepoRef) -> Bool {
        let query = search.trimmingCharacters(in: .whitespaces)
        return query.isEmpty || repo.name.localizedCaseInsensitiveContains(query)
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
                if newMode != mode { controller.setOwnerMode(newMode, for: owner.login) }
            }
        )
    }

    private func notifications(for repo: RepoRef) -> Binding<Bool> {
        Binding(
            get: { !watch.notificationsOff.contains(repo.id) },
            set: { controller.setNotifications($0, for: repo.id) }
        )
    }
}

/// A repository with its watch checkbox and, while watched, a notification bell.
private struct RepoRow: View {
    let repo: RepoRef
    @Binding var isWatched: Bool
    @Binding var notifications: Bool

    var body: some View {
        HStack {
            Toggle(isOn: $isWatched) {
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
            Spacer()
            if isWatched {
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
