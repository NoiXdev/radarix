import Foundation

public enum OwnerAccessIssue: Sendable, Equatable {
    case restricted(message: String?)
}

public enum RepoResolver {
    /// Repos to watch for the given config, sorted by full name (case-insensitive).
    /// `available` is keyed by owner login.
    public static func watched(config: WatchConfig, available: [String: [RepoRef]]) -> [RepoRef] {
        var result: [RepoRef] = []
        for (owner, mode) in config.owners {
            let repos = available[owner] ?? []
            switch mode {
            case .off:
                break
            case .all(let excluded):
                result += repos.filter {
                    !excluded.contains($0.id) && !$0.isFork && (config.showArchived || !$0.isArchived)
                }
            case .selected(let ids):
                result += repos.filter { ids.contains($0.id) && (config.showArchived || !$0.isArchived) }
            }
        }
        return result.sorted { $0.fullName.localizedCaseInsensitiveCompare($1.fullName) == .orderedAscending }
    }

    /// Ids of the stored repo states whose owner is in `owners`. A sync keeps these untouched
    /// when their owner's repo list is unknown.
    public static func stored(in account: AccountData, ownedBy owners: Set<String>) -> Set<RepoID> {
        Set(account.repos.values.filter { owners.contains($0.repo.owner) }.map(\.repo.id))
    }
}
