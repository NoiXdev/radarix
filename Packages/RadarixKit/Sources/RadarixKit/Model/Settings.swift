import Foundation

public enum MainLayout: String, Codable, Sendable { case sidebar, grouped }
public enum BotDisplayMode: String, Codable, Sendable { case badge, grouped, hidden }
public enum DescriptionPlacement: String, Codable, Sendable { case window, sidebar }

public struct AppSettings: Codable, Sendable, Equatable {
    /// Version of the file layout. Files written before versioning decode as 1; saving always writes the current one.
    public static let currentSchemaVersion = 5
    public var schemaVersion = AppSettings.currentSchemaVersion
    public var layout: MainLayout = .sidebar
    public var refreshInterval: TimeInterval = 300
    public static let refreshIntervals: [TimeInterval] = [120, 300, 600, 900, 1800]
    public var botDisplay: BotDisplayMode = .badge
    public var notifyBots = false
    public var notifyUpdated = false
    public var openAtLogin = false
    public var checkForUpdates = true
    /// Signed-in accounts, oldest first. The order decides repo ownership and sidebar order.
    public var accountIDs: [AccountID] = []
    /// The main list's filter chips, kept across launches.
    public var filter = FilterSet()
    /// The Bots chip, only offered while bots form their own group.
    public var showsBots = false
    /// Group the "All" list by repository.
    public var groupAllByRepo = false
    /// Where the item description shows: its own window, or inline below the sidebar's details.
    public var descriptionPlacement: DescriptionPlacement = .window
    /// When on, no launch opens the main window. The menu bar item opens it.
    public var startInBackground = false
    /// When on, closing the last Radarix window hides the Dock icon and leaves the app in the menu bar.
    public var menuBarOnlyWhenClosed = false

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, layout, refreshInterval, botDisplay, notifyBots, notifyUpdated, openAtLogin, checkForUpdates, accountIDs
        case filter, showsBots, groupAllByRepo
        case descriptionPlacement, startInBackground, menuBarOnlyWhenClosed
        /// Schema 1 and 2 only; decoded into `accountIDs`, never written.
        case lastAccountID
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
        checkForUpdates = try c.decodeIfPresent(Bool.self, forKey: .checkForUpdates) ?? defaults.checkForUpdates
        filter = try c.decodeIfPresent(FilterSet.self, forKey: .filter) ?? defaults.filter
        showsBots = try c.decodeIfPresent(Bool.self, forKey: .showsBots) ?? defaults.showsBots
        groupAllByRepo = try c.decodeIfPresent(Bool.self, forKey: .groupAllByRepo) ?? defaults.groupAllByRepo
        // Read as a raw string so an unknown value falls back instead of failing the whole file.
        let placement = try c.decodeIfPresent(String.self, forKey: .descriptionPlacement)
        descriptionPlacement = placement.flatMap(DescriptionPlacement.init(rawValue:)) ?? defaults.descriptionPlacement
        startInBackground = try c.decodeIfPresent(Bool.self, forKey: .startInBackground) ?? defaults.startInBackground
        menuBarOnlyWhenClosed = try c.decodeIfPresent(Bool.self, forKey: .menuBarOnlyWhenClosed) ?? defaults.menuBarOnlyWhenClosed
        if let ids = try c.decodeIfPresent([AccountID].self, forKey: .accountIDs) {
            accountIDs = ids
        } else if let legacy = try c.decodeIfPresent(AccountID.self, forKey: .lastAccountID) {
            accountIDs = [legacy]
        }
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
        try c.encode(checkForUpdates, forKey: .checkForUpdates)
        try c.encode(accountIDs, forKey: .accountIDs)
        try c.encode(filter, forKey: .filter)
        try c.encode(showsBots, forKey: .showsBots)
        try c.encode(groupAllByRepo, forKey: .groupAllByRepo)
        try c.encode(descriptionPlacement, forKey: .descriptionPlacement)
        try c.encode(startInBackground, forKey: .startInBackground)
        try c.encode(menuBarOnlyWhenClosed, forKey: .menuBarOnlyWhenClosed)
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
    public static let currentSchemaVersion = 3
    public var schemaVersion = AccountData.currentSchemaVersion
    public let accountID: AccountID
    public var login: String
    public var watch = WatchConfig()
    public var repos: [RepoID: RepoState] = [:]
    /// Repo list of every active owner from the last resolution, keyed by owner login.
    public var available: [String: [RepoRef]] = [:]

    public init(
        accountID: AccountID, login: String, watch: WatchConfig = WatchConfig(), repos: [RepoID: RepoState] = [:],
        available: [String: [RepoRef]] = [:]
    ) {
        self.accountID = accountID
        self.login = login
        self.watch = watch
        self.repos = repos
        self.available = available
    }

    private enum CodingKeys: String, CodingKey { case schemaVersion, accountID, login, watch, repos, available }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        accountID = try c.decode(AccountID.self, forKey: .accountID)
        login = try c.decode(String.self, forKey: .login)
        watch = try c.decodeIfPresent(WatchConfig.self, forKey: .watch) ?? WatchConfig()
        repos = try c.decodeIfPresent([RepoID: RepoState].self, forKey: .repos) ?? [:]
        available = try c.decodeIfPresent([String: [RepoRef]].self, forKey: .available) ?? [:]
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Self.currentSchemaVersion, forKey: .schemaVersion)
        try c.encode(accountID, forKey: .accountID)
        try c.encode(login, forKey: .login)
        try c.encode(watch, forKey: .watch)
        try c.encode(repos, forKey: .repos)
        try c.encode(available, forKey: .available)
    }
}
