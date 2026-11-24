import AppIntents
import RadarixKit
import WidgetKit

/// The widget's configuration: which repositories it summarizes. No scope means all of them.
struct ScopeIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Radarix"
    static let description = IntentDescription("Shows new and updated items.")

    @Parameter(title: "Show")
    var scope: ScopeEntity?

    init() {}

    init(scope: ScopeEntity?) {
        self.scope = scope
    }
}

/// A choice for `ScopeIntent.scope`: all repositories, one owner or one repository.
///
/// The id is `all`, `owner:<login>` or `repo:<repo id>`.
struct ScopeEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Repositories")
    static let defaultQuery = ScopeQuery()

    static let allID = "all"
    private static let ownerPrefix = "owner:"
    private static let repoPrefix = "repo:"

    let id: String
    let name: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }

    static var all: ScopeEntity {
        ScopeEntity(id: allID, name: String(localized: "All repositories"))
    }

    static func owner(_ login: String) -> ScopeEntity {
        ScopeEntity(id: ownerPrefix + login, name: login)
    }

    static func repo(_ repo: WidgetSnapshot.RepoEntry) -> ScopeEntity {
        ScopeEntity(id: repoPrefix + String(repo.id.rawValue), name: repo.fullName)
    }

    /// "All repositories", each owner, then each repository by `owner/name`.
    /// A missing or signed-out snapshot offers only "All repositories".
    static func choices(in snapshot: WidgetSnapshot?) -> [ScopeEntity] {
        guard let snapshot, snapshot.status != .signedOut else { return [.all] }
        let repos = snapshot.repos.sorted { a, b in
            let order = a.fullName.caseInsensitiveCompare(b.fullName)
            return order == .orderedSame ? a.id.rawValue < b.id.rawValue : order == .orderedAscending
        }
        return [.all] + snapshot.owners.map(owner) + repos.map(repo)
    }

    /// `all` or nil gives `.all`, `owner:x` gives `.owner(x)` while the snapshot has repositories
    /// of owner x (case-insensitively), and `repo:<id>` gives `.repo` while that repository is
    /// still in the snapshot. Anything else falls back to `.all`.
    static func scope(forID id: String?, in snapshot: WidgetSnapshot?) -> WidgetScope {
        guard let id else { return .all }
        if id.hasPrefix(ownerPrefix) {
            let login = String(id.dropFirst(ownerPrefix.count))
            let known = snapshot?.owners.contains { $0.caseInsensitiveCompare(login) == .orderedSame } == true
            return known ? .owner(login) : .all
        }
        if id.hasPrefix(repoPrefix), let raw = Int64(id.dropFirst(repoPrefix.count)) {
            let repo = RepoID(rawValue: raw)
            return snapshot?.repos.contains(where: { $0.id == repo }) == true ? .repo(repo) : .all
        }
        return .all
    }
}

/// Lists the scopes from the snapshot the app last wrote. Reads only.
struct ScopeQuery: EntityQuery {
    func entities(for identifiers: [ScopeEntity.ID]) async throws -> [ScopeEntity] {
        let choices = ScopeEntity.choices(in: SnapshotReader.load())
        return identifiers.compactMap { id in choices.first(where: { $0.id == id }) }
    }

    func suggestedEntities() async throws -> [ScopeEntity] {
        ScopeEntity.choices(in: SnapshotReader.load())
    }

    func defaultResult() async -> ScopeEntity? {
        .all
    }
}
