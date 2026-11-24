import Foundation

/// Which repos a widget summarizes.
public enum WidgetScope: Sendable, Hashable, Codable {
    case all, owner(String), repo(RepoID)
}

/// What the widget extension reads from the shared directory. It holds no credential and no
/// account id: only the fields declared here end up in `widget-snapshot.json`.
public struct WidgetSnapshot: Codable, Sendable, Equatable {
    public enum Status: String, Codable, Sendable { case ok, needsReauth, signedOut }

    public struct ItemEntry: Codable, Sendable, Equatable, Identifiable {
        public let key: ItemKey
        public let kind: ItemKind
        public let title: String
        public let attention: Attention
        public let updatedAt: Date
        public let isDraft: Bool
        /// `Actor.botDisplayName`, nil for humans.
        public let botName: String?
        public var id: ItemKey { key }

        public init(
            key: ItemKey, kind: ItemKind, title: String, attention: Attention, updatedAt: Date,
            isDraft: Bool, botName: String?
        ) {
            self.key = key
            self.kind = kind
            self.title = title
            self.attention = attention
            self.updatedAt = updatedAt
            self.isDraft = isDraft
            self.botName = botName
        }

        init(_ record: ItemRecord) {
            let item = record.item
            self.init(
                key: item.key, kind: item.kind, title: item.title, attention: record.attention,
                updatedAt: item.updatedAt, isDraft: item.isDraft, botName: item.author.botDisplayName)
        }
    }

    public struct RepoEntry: Codable, Sendable, Equatable, Identifiable {
        public let id: RepoID
        public let owner: String
        public let name: String
        public let newCount: Int
        public let updatedCount: Int
        /// The newest `itemsPerRepo` new or updated items, `updatedAt` descending.
        public let items: [ItemEntry]
        public var fullName: String { "\(owner)/\(name)" }

        public init(id: RepoID, owner: String, name: String, newCount: Int, updatedCount: Int, items: [ItemEntry]) {
            self.id = id
            self.owner = owner
            self.name = name
            self.newCount = newCount
            self.updatedCount = updatedCount
            self.items = items
        }

        var total: Int { newCount + updatedCount }
    }

    public struct Summary: Sendable, Equatable {
        public let newCount: Int
        public let updatedCount: Int
        /// Total descending, then `fullName`.
        public let repos: [RepoEntry]
        /// Every item of `repos`, `updatedAt` descending, then key.
        public let items: [ItemEntry]
        public var busiestRepo: RepoEntry? { repos.first(where: { $0.newCount + $0.updatedCount > 0 }) }
    }

    public static let itemsPerRepo = 6
    /// The widget calls its data stale this long after `syncedAt`.
    public static let staleAfter: TimeInterval = 2 * 60 * 60

    public var status: Status
    /// Every signed-in account, in account order.
    public var logins: [String]
    /// The accounts of `logins` whose sign-in expired.
    public var reauthLogins: [String]
    public var syncedAt: Date?
    public var repos: [RepoEntry]

    public init(status: Status, logins: [String], reauthLogins: [String], syncedAt: Date?, repos: [RepoEntry]) {
        self.status = status
        self.logins = logins
        self.reauthLogins = reauthLogins
        self.syncedAt = syncedAt
        self.repos = repos
    }

    public static let signedOut = WidgetSnapshot(status: .signedOut, logins: [], reauthLogins: [], syncedAt: nil, repos: [])

    private enum CodingKeys: String, CodingKey {
        case status, logins, reauthLogins, syncedAt, repos
        /// Written by the single-account schema; read only.
        case login
    }

    /// Tolerant: a file of the single-account schema has `login` and no `logins`.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        status = try c.decode(Status.self, forKey: .status)
        if let logins = try c.decodeIfPresent([String].self, forKey: .logins) {
            self.logins = logins
        } else if let login = try c.decodeIfPresent(String.self, forKey: .login) {
            logins = [login]
        } else {
            logins = []
        }
        reauthLogins = try c.decodeIfPresent([String].self, forKey: .reauthLogins) ?? []
        syncedAt = try c.decodeIfPresent(Date.self, forKey: .syncedAt)
        repos = try c.decodeIfPresent([RepoEntry].self, forKey: .repos) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(status, forKey: .status)
        try c.encode(logins, forKey: .logins)
        try c.encode(reauthLogins, forKey: .reauthLogins)
        try c.encodeIfPresent(syncedAt, forKey: .syncedAt)
        try c.encode(repos, forKey: .repos)
    }

    /// Counts and items follow `ItemFilter.counts`: listed new and updated records, without bots
    /// only in `.hidden` mode. Every given repo gets an entry, also one with nothing to show.
    /// `.signedOut` without logins, `.needsReauth` when every login needs it, else `.ok`.
    public static func make(
        repos states: [RepoState], logins: [String], reauthLogins: [String], settings: AppSettings, syncedAt: Date?
    ) -> WidgetSnapshot {
        let status: Status = if logins.isEmpty {
            .signedOut
        } else if logins.allSatisfy({ login in reauthLogins.contains { $0.caseInsensitiveCompare(login) == .orderedSame } }) {
            .needsReauth
        } else {
            .ok
        }
        let repos = states.map { state in
            let shown = state.records.values.filter { record in
                ItemStateEngine.isListed(record) && record.attention != .seen
                    && !(settings.botDisplay == .hidden && record.item.author.isBot)
            }
            let newest = shown.sorted { newer($0.item.updatedAt, $0.item.key, than: $1.item.updatedAt, $1.item.key) }
            return RepoEntry(
                id: state.repo.id, owner: state.repo.owner, name: state.repo.name,
                newCount: shown.count(where: { $0.attention == .new }),
                updatedCount: shown.count(where: { $0.attention == .updated }),
                items: newest.prefix(itemsPerRepo).map(ItemEntry.init))
        }
        return WidgetSnapshot(
            status: status, logins: logins, reauthLogins: reauthLogins, syncedAt: syncedAt, repos: sorted(repos))
    }

    /// An unknown repo or owner gives an empty summary; the widget picks its own fallback.
    public func summary(for scope: WidgetScope) -> Summary {
        let chosen = switch scope {
        case .all: repos
        case .owner(let login): repos.filter { $0.owner.caseInsensitiveCompare(login) == .orderedSame }
        case .repo(let id): repos.filter { $0.id == id }
        }
        let items = chosen.flatMap(\.items)
            .sorted { Self.newer($0.updatedAt, $0.key, than: $1.updatedAt, $1.key) }
        return Summary(
            newCount: chosen.reduce(0) { $0 + $1.newCount },
            updatedCount: chosen.reduce(0) { $0 + $1.updatedCount },
            repos: Self.sorted(chosen), items: items)
    }

    /// Distinct owners of `repos`, sorted case-insensitively.
    public var owners: [String] {
        Set(repos.map(\.owner)).sorted { a, b in
            let order = a.caseInsensitiveCompare(b)
            return order == .orderedSame ? a < b : order == .orderedAscending
        }
    }

    /// Total descending, then `fullName` case-insensitively, then id.
    private static func sorted(_ repos: [RepoEntry]) -> [RepoEntry] {
        repos.sorted { a, b in
            if a.total != b.total { return a.total > b.total }
            let order = a.fullName.caseInsensitiveCompare(b.fullName)
            if order != .orderedSame { return order == .orderedAscending }
            return a.id.rawValue < b.id.rawValue
        }
    }

    /// The order of `ItemFilter.visible`: `updatedAt` descending, then repo id, then number.
    private static func newer(_ date: Date, _ key: ItemKey, than otherDate: Date, _ other: ItemKey) -> Bool {
        if date != otherDate { return date > otherDate }
        if key.repo != other.repo { return key.repo.rawValue < other.repo.rawValue }
        return key.number < other.number
    }
}
