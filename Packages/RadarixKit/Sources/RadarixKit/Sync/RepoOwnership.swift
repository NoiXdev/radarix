import Foundation

/// Decides which account syncs a repo that several accounts watch.
public enum RepoOwnership {
    /// `watched` is in account order; the first account listing a repo id owns it.
    public static func assign(_ watched: [(AccountID, [RepoRef])]) -> [RepoID: AccountID] {
        var owners: [RepoID: AccountID] = [:]
        for (account, repos) in watched {
            for repo in repos where owners[repo.id] == nil {
                owners[repo.id] = account
            }
        }
        return owners
    }
}
