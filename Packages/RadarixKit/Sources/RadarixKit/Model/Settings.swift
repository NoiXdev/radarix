import Foundation

public enum MainLayout: String, Codable, Sendable { case sidebar, grouped }
public enum BotDisplayMode: String, Codable, Sendable { case badge, grouped, hidden }

public struct AppSettings: Codable, Sendable, Equatable {
    /// Version of the file layout. Files written before versioning decode as 1; saving always writes the current one.
    public static let currentSchemaVersion = 2
    public var schemaVersion = AppSettings.currentSchemaVersion
    public var layout: MainLayout = .sidebar
    public var refreshInterval: TimeInterval = 300
    public static let refreshIntervals: [TimeInterval] = [120, 300, 600, 900, 1800]
    public var botDisplay: BotDisplayMode = .badge
    public var notifyBots = false
    public var notifyUpdated = false
    public var openAtLogin = false
    public var lastAccountID: AccountID?

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, layout, refreshInterval, botDisplay, notifyBots, notifyUpdated, openAtLogin, lastAccountID
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AppSettings()
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        layout = try c.decodeIfPresent(MainLayout.self, forKey: .layout) ?? defaults.layout
        refreshInterval = try c.decodeIfPresent(TimeInterval.self, forKey: .refreshInterval) ?? defaults.refreshInterval
        botDisplay = try c.decodeIfPresent(BotDisplayMode.self, forKey: .botDisplay) ?? defaults.botDisplay
        notifyBots = try c.decodeIfPresent(Bool.self, forKey: .notifyBots) ?? defaults.notifyBots
        notifyUpdated = try c.decodeIfPresent(Bool.self, forKey: .notifyUpdated) ?? defaults.notifyUpdated
        openAtLogin = try c.decodeIfPresent(Bool.self, forKey: .openAtLogin) ?? defaults.openAtLogin
        lastAccountID = try c.decodeIfPresent(AccountID.self, forKey: .lastAccountID)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Self.currentSchemaVersion, forKey: .schemaVersion)
        try c.encode(layout, forKey: .layout)
        try c.encode(refreshInterval, forKey: .refreshInterval)
        try c.encode(botDisplay, forKey: .botDisplay)
        try c.encode(notifyBots, forKey: .notifyBots)
        try c.encode(notifyUpdated, forKey: .notifyUpdated)
        try c.encode(openAtLogin, forKey: .openAtLogin)
        try c.encodeIfPresent(lastAccountID, forKey: .lastAccountID)
    }
}

public enum OwnerMode: Codable, Sendable, Equatable {
    case off
    case all(excluded: Set<RepoID>)
    case selected(Set<RepoID>)
}

public struct WatchConfig: Codable, Sendable, Equatable {
    /// Key: owner login. A missing owner is `.off`.
    public var owners: [String: OwnerMode] = [:]
    public var showArchived = false
    public var notificationsOff: Set<RepoID> = []

    public init() {}

    private enum CodingKeys: String, CodingKey { case owners, showArchived, notificationsOff }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        owners = try c.decodeIfPresent([String: OwnerMode].self, forKey: .owners) ?? [:]
        showArchived = try c.decodeIfPresent(Bool.self, forKey: .showArchived) ?? false
        notificationsOff = try c.decodeIfPresent(Set<RepoID>.self, forKey: .notificationsOff) ?? []
    }
}

public struct RepoState: Codable, Sendable, Equatable {
    public var repo: RepoRef
    public var baselineAt: Date?
    /// Max `updatedAt` seen for this repo.
    public var highWaterMark: Date?
    /// Key: issue number.
    public var records: [Int: ItemRecord]
    /// Plain diagnostic string, not meant to be shown raw to users.
    public var lastFailure: String?

    public init(
        repo: RepoRef, baselineAt: Date? = nil, highWaterMark: Date? = nil,
        records: [Int: ItemRecord] = [:], lastFailure: String? = nil
    ) {
        self.repo = repo
        self.baselineAt = baselineAt
        self.highWaterMark = highWaterMark
        self.records = records
        self.lastFailure = lastFailure
    }

    private enum CodingKeys: String, CodingKey { case repo, baselineAt, highWaterMark, records, lastFailure }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        repo = try c.decode(RepoRef.self, forKey: .repo)
        baselineAt = try c.decodeIfPresent(Date.self, forKey: .baselineAt)
        highWaterMark = try c.decodeIfPresent(Date.self, forKey: .highWaterMark)
        records = try c.decodeIfPresent([Int: ItemRecord].self, forKey: .records) ?? [:]
        lastFailure = try c.decodeIfPresent(String.self, forKey: .lastFailure)
    }
}

public struct AccountData: Codable, Sendable, Equatable {
    /// Version of the file layout. Files written before versioning decode as 1; saving always writes the current one.
    public static let currentSchemaVersion = 2
    public var schemaVersion = AccountData.currentSchemaVersion
    public let accountID: AccountID
    public var login: String
    public var watch = WatchConfig()
    public var repos: [RepoID: RepoState] = [:]

    public init(accountID: AccountID, login: String, watch: WatchConfig = WatchConfig(), repos: [RepoID: RepoState] = [:]) {
        self.accountID = accountID
        self.login = login
        self.watch = watch
        self.repos = repos
    }

    private enum CodingKeys: String, CodingKey { case schemaVersion, accountID, login, watch, repos }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        accountID = try c.decode(AccountID.self, forKey: .accountID)
        login = try c.decode(String.self, forKey: .login)
        watch = try c.decodeIfPresent(WatchConfig.self, forKey: .watch) ?? WatchConfig()
        repos = try c.decodeIfPresent([RepoID: RepoState].self, forKey: .repos) ?? [:]
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Self.currentSchemaVersion, forKey: .schemaVersion)
        try c.encode(accountID, forKey: .accountID)
        try c.encode(login, forKey: .login)
        try c.encode(watch, forKey: .watch)
        try c.encode(repos, forKey: .repos)
    }
}
