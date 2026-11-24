import Foundation

public enum MainLayout: String, Codable, Sendable { case sidebar, grouped }
public enum BotDisplayMode: String, Codable, Sendable { case badge, grouped, hidden }

public struct AppSettings: Codable, Sendable, Equatable {
    public var layout: MainLayout = .sidebar
    public var refreshInterval: TimeInterval = 300
    public static let refreshIntervals: [TimeInterval] = [120, 300, 600, 900, 1800]
    public var botDisplay: BotDisplayMode = .badge
    public var notifyBots = false
    public var notifyUpdated = false
    public var openAtLogin = false
    public var lastAccountID: AccountID?

    public init() {}
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
}

public struct AccountData: Codable, Sendable, Equatable {
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
}
