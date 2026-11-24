import Foundation
import Observation
import RadarixKit
import UserNotifications

/// What a clicked notification leads to.
enum NotificationTarget: Sendable, Equatable {
    /// An item notification: open its GitHub page and mark it seen.
    case item(ItemKey, URL)
    /// A summary: show the repo in the main window, marking nothing.
    case repo(RepoID)
}

/// Posts planned notifications and turns clicks into targets. A banner itself never marks
/// anything seen; only `onOpen` for an item click does that.
@MainActor @Observable
final class NotificationService: NSObject, UNUserNotificationCenterDelegate {
    /// The user turned notifications off for Radarix in System Settings.
    private(set) var authorizationDenied = false

    /// Called on the main actor when the user clicks a notification.
    @ObservationIgnored var onOpen: ((NotificationTarget) -> Void)?
    /// Looks up the repo an item notification belongs to; nil drops that notification.
    @ObservationIgnored var repo: ((RepoID) -> RepoRef?)?

    /// The one authorization request of this launch, shared by everyone who waits on it.
    @ObservationIgnored private var authorization: Task<Void, Never>?

    private enum Key {
        static let url = "url", repo = "repo", number = "number", link = "link"
    }

    /// Asks for permission the first time in a launch; later calls wait for that answer.
    func requestAuthorizationIfNeeded() async {
        if let authorization { return await authorization.value }
        let task = Task {
            _ = await Self.requestAuthorization()
            await refreshAuthorizationStatus()
        }
        authorization = task
        await task.value
    }

    /// Reads whether notifications are turned off for Radarix.
    func refreshAuthorizationStatus() async {
        authorizationDenied = await Self.isDenied()
    }

    /// Removes Radarix's delivered and not yet delivered notifications, for a sign-out or a reset.
    func removeAll() {
        let center = UNUserNotificationCenter.current()
        center.removeAllDeliveredNotifications()
        center.removeAllPendingNotificationRequests()
    }

    /// Removes the delivered and not yet delivered notifications of `repos`, for a removed account.
    func remove(forRepos repos: Set<RepoID>) {
        guard !repos.isEmpty else { return }
        let threads = Set(repos.map(Self.thread(of:)))
        Task { await Self.remove(threads: threads) }
    }

    /// A non-nil `accountLogin` names the account the notifications belong to, ahead of the subtitle.
    func post(_ planned: [PlannedNotification], accountLogin: String?) {
        let center = UNUserNotificationCenter.current()
        for notification in planned {
            guard let content = content(for: notification, accountLogin: accountLogin) else { continue }
            let request = UNNotificationRequest(identifier: notification.id, content: content, trigger: nil)
            center.add(request, withCompletionHandler: nil)
        }
    }

    private func content(for planned: PlannedNotification, accountLogin: String?) -> UNNotificationContent? {
        let content = UNMutableNotificationContent()
        content.sound = .default
        switch planned.content {
        case .item(let item, let attention):
            guard let repo = repo?(item.key.repo) else { return nil }
            content.title = repo.fullName
            content.subtitle = Self.subtitle(Self.subtitle(kind: item.kind, attention: attention), accountLogin: accountLogin)
            content.body = item.title
            content.threadIdentifier = Self.thread(of: repo.id)
            content.userInfo = [
                Key.url: item.url.absoluteString,
                Key.repo: item.key.repo.rawValue,
                Key.number: item.key.number,
            ]
        case .summary(let repo, let newCount, let updatedCount):
            content.title = repo.fullName
            var parts: [String] = []
            if newCount > 0 || updatedCount == 0 { parts.append(String(localized: "\(newCount) new items")) }
            if updatedCount > 0 { parts.append(String(localized: "\(updatedCount) updated items")) }
            content.subtitle = Self.subtitle("", accountLogin: accountLogin)
            content.body = parts.joined(separator: " · ")
            content.threadIdentifier = Self.thread(of: repo.id)
            content.userInfo = [Key.link: DeepLink.repo(repo.id).url.absoluteString]
        }
        return content
    }

    /// Groups a repo's notifications; every notification Radarix posts belongs to one repo's thread.
    private nonisolated static func thread(of repo: RepoID) -> String {
        "repo-\(repo.rawValue)"
    }

    /// `"<login> · <subtitle>"`, the login alone for an empty subtitle, the subtitle alone without a login.
    private static func subtitle(_ subtitle: String, accountLogin: String?) -> String {
        guard let accountLogin else { return subtitle }
        return subtitle.isEmpty ? accountLogin : "\(accountLogin) · \(subtitle)"
    }

    private static func subtitle(kind: ItemKind, attention: Attention) -> String {
        switch (kind, attention) {
        case (.pullRequest, .updated): String(localized: "Updated pull request")
        case (.issue, .updated): String(localized: "Updated issue")
        case (.pullRequest, _): String(localized: "New pull request")
        case (.issue, _): String(localized: "New issue")
        }
    }

    // MARK: System calls (plain values only cross the actor boundary)

    private nonisolated static func requestAuthorization() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }

    private nonisolated static func remove(threads: Set<String>) async {
        let center = UNUserNotificationCenter.current()
        let delivered = await center.deliveredNotifications()
            .filter { threads.contains($0.request.content.threadIdentifier) }
            .map(\.request.identifier)
        center.removeDeliveredNotifications(withIdentifiers: delivered)
        let pending = await center.pendingNotificationRequests()
            .filter { threads.contains($0.content.threadIdentifier) }
            .map(\.identifier)
        center.removePendingNotificationRequests(withIdentifiers: pending)
    }

    private nonisolated static func isDenied() async -> Bool {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus == .denied
    }

    /// Nil for a dismissal or a notification Radarix did not post.
    private nonisolated static func target(of response: UNNotificationResponse) -> NotificationTarget? {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier else { return nil }
        let info = response.notification.request.content.userInfo
        if let link = info[Key.link] as? String, let url = URL(string: link),
           case .repo(let id) = DeepLink(url: url) {
            return .repo(id)
        }
        guard let string = info[Key.url] as? String, let url = URL(string: string),
              let repo = (info[Key.repo] as? NSNumber)?.int64Value,
              let number = (info[Key.number] as? NSNumber)?.intValue
        else { return nil }
        return .item(ItemKey(repo: RepoID(rawValue: repo), number: number), url)
    }

    // MARK: UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        guard let target = Self.target(of: response) else { return }
        await MainActor.run { onOpen?(target) }
    }
}
