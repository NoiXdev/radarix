import Foundation
import RadarixKit

extension RadarixController {
    /// The watched repositories per account, in the order the sidebar shows them: accounts in
    /// session order, each account's repos ordered like its owners list, then by owner and name.
    /// An account that owns no watched repo comes back with an empty list.
    func orderedRepos(in repos: [RepoID: RepoState]) -> [(session: AccountSession, repos: [RepoRef])] {
        let byOwner = Dictionary(grouping: repos.values.map(\.repo)) { owner(of: $0.id)?.accountID }
        return sessions.map { session in
            let ownerOrder = Dictionary(
                session.owners.enumerated().map { ($1.login, $0) }, uniquingKeysWith: { first, _ in first }
            )
            let owned = (byOwner[session.accountID] ?? []).sorted { a, b in
                let rankA = ownerOrder[a.owner] ?? .max, rankB = ownerOrder[b.owner] ?? .max
                if rankA != rankB { return rankA < rankB }
                if a.owner != b.owner { return a.owner.localizedCaseInsensitiveCompare(b.owner) == .orderedAscending }
                return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
            return (session, owned)
        }
    }
}
