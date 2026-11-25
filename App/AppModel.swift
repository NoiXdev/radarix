import AppKit
import Observation
import RadarixKit
import WidgetKit
#if DEBUG
import os
#endif

/// An assign or unassign that failed, ready to show: the item as `owner/name #number`, and why.
struct AssignFailure: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let message: String
}

/// Owns the controller for the app's lifetime and maps kit errors to user-facing text.
@MainActor @Observable
final class AppModel {
    let controller: RadarixController
    let notifications = NotificationService()
    /// Nil when the bundle version does not parse; nothing is checked or shown then.
    let updates: UpdateChecker?
    /// Empty when this build has no OAuth App; the token sign-in still works.
    let oauthClientID: String
    /// Set once per launch by the app delegate, through `setLaunchKind(atLogin:)`.
    private(set) var launchedAtLogin = false
    /// This launch hands over to another running instance: it never starts, opens no window and
    /// shows no menu bar item.
    private(set) var isYielding = false
    /// A link the main window should show next; it sets this back to nil once handled.
    /// Kept only while it can still be shown: never across a sign-out or a reset.
    var navigation: DeepLink?
    /// The last assign failure nobody else showed: from the context menu, or from an inline
    /// button whose view was gone. The main window shows it as an alert and clears it.
    var assignFailure: AssignFailure?

    /// Set by the app delegate: brings the Dock icon in step with the open windows and the setting.
    @ObservationIgnored var updateDockIcon: @MainActor () -> Void = {}

    @ObservationIgnored private var started = false
    @ObservationIgnored private var launchWindowClaimed = false
    @ObservationIgnored private var launchKindKnown = false
    /// `claimLaunchWindow()` calls waiting for `setLaunchKind(atLogin:)`.
    @ObservationIgnored private var launchKindWaiters: [CheckedContinuation<Void, Never>] = []
    /// Set once `restoreSessions` has returned; marks made before that are kept until then.
    @ObservationIgnored private var sessionRestored = false
    /// Item notifications clicked before the session was restored (a click that launched the app).
    @ObservationIgnored private var pendingSeen: [ItemKey] = []

    init() {
        let clientID = Self.infoValue("GitHubOAuthClientID")
        oauthClientID = clientID
        controller = RadarixController(
            store: FileStore(directory: FileStore.defaultDirectory(appGroup: Self.infoValue("RadarixAppGroup"))),
            credentials: KeychainCredentialStore(),
            makeAPI: { GitHubClient(token: $0) },
            oauthClientID: clientID
        )
        if let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            let current = AppVersion(version)
        {
            updates = UpdateChecker(current: current, source: GitHubReleaseSource(userAgent: "Radarix/\(current)"))
        } else {
            updates = nil
        }
        controller.onSyncReport = { [weak self] account, report in self?.didSync(account: account, report: report) }
        controller.onSnapshotWritten = { WidgetCenter.shared.reloadAllTimelines() }
        notifications.repo = { [weak self] id in self?.controller.repos[id]?.repo }
        notifications.onOpen = { [weak self] target in self?.openNotification(target) }
    }

    /// Writes the setting and starts or stops the update check to match.
    func setCheckForUpdates(_ on: Bool) {
        controller.updateSettings { $0.checkForUpdates = on }
        updates?.setEnabled(on)
    }

    /// Writes the setting and shows or hides the Dock icon to match. Turned off, the icon is back at once.
    func setMenuBarOnlyWhenClosed(_ on: Bool) {
        controller.updateSettings { $0.menuBarOnlyWhenClosed = on }
        updateDockIcon()
    }

    var isDeviceFlowAvailable: Bool { !oauthClientID.isEmpty }

    /// Restores the stored accounts and starts periodic syncing. Runs once per launch, and never
    /// in a launch that hands over to another instance.
    func start() {
        guard !started, !isYielding else { return }
        started = true
        updates?.setEnabled(controller.settings.checkForUpdates)
        Task {
            await controller.restoreSessions()
            sessionRestored = true
            // A link that launched a signed-out Radarix must not fire after a later sign-in.
            if !controller.isSignedIn { navigation = nil }
            for key in pendingSeen { controller.markSeen(key) }
            pendingSeen = []
            controller.startScheduler()
        }
    }

    // MARK: Notifications

    /// Plans one session's notifications now, while its account matches the report. The banner
    /// names the account only while there is more than one. The first report of a launch asks for
    /// permission and posts once the user has answered.
    private func didSync(account: AccountData, report: SyncReport) {
        let planned = NotificationPlanner.plan(report, account: account, settings: controller.settings)
        let accountLogin = controller.sessions.count > 1 ? account.login : nil
        Task {
            await notifications.requestAuthorizationIfNeeded()
            notifications.post(planned, accountLogin: accountLogin)
        }
    }

    /// A clicked notification. Only an item click marks something seen.
    private func openNotification(_ target: NotificationTarget) {
        switch target {
        case .item(let key, let url):
            NSWorkspace.shared.open(url)
            if sessionRestored {
                controller.markSeen(key)
            } else {
                pendingSeen.append(key)
            }
        case .repo(let id):
            open(DeepLink.repo(id))
        }
    }

    /// Records whether this launch was made at login. Only the first call of a launch counts:
    /// the open-application event, or else the end of launching.
    func setLaunchKind(atLogin: Bool) {
        guard !launchKindKnown else { return }
        launchedAtLogin = atLogin
        launchKindKnown = true
        #if DEBUG
        Logger(subsystem: "dev.noix.radarix", category: "launch")
            .notice("Launch kind known: launchedAtLogin = \(atLogin, privacy: .public)")
        #endif
        let waiters = launchKindWaiters
        launchKindWaiters = []
        for waiter in waiters { waiter.resume() }
    }

    /// True at most once per launch, for a launch not made at login, with "Start in the background"
    /// off, and only while no main window has appeared: the caller then opens the main window, which
    /// the window group itself suppresses at launch. Waits until the launch kind is known.
    /// A launch left without a window updates the Dock icon, which "menu bar only" then hides.
    func claimLaunchWindow() async -> Bool {
        if !launchKindKnown {
            await withCheckedContinuation { launchKindWaiters.append($0) }
        }
        guard !launchWindowClaimed else { return false }
        launchWindowClaimed = true
        let opens = !launchedAtLogin && !controller.settings.startInBackground
        if !opens { updateDockIcon() }
        return opens
    }

    /// This launch hands over to another running instance: it opens no launch window,
    /// `start()` does nothing and the menu bar item goes.
    func yieldToOtherInstance() {
        isYielding = true
        launchWindowClaimed = true
    }

    /// A main window is on screen, so the launch needs no other. A launch for a `radarix://` link
    /// gets its window from the window group (no launch Apple event tells it apart), and that
    /// window appears before the menu bar label claims the launch window.
    func mainWindowAppeared() {
        launchWindowClaimed = true
    }

    /// A link a main window received, for `navigation`. While signed out after the launch it is
    /// dropped: the window only comes to the front.
    func receive(_ link: DeepLink) {
        if sessionRestored, !controller.isSignedIn { return }
        navigation = link
    }

    /// Shows `link` in the main window, opening one if none is open. Needs no `openWindow`:
    /// the system hands the link back to the main window group. Sent to this copy of Radarix:
    /// another copy would be launched only to hand over back to this one.
    func open(_ link: DeepLink) {
        NSWorkspace.shared.open(
            [link.url], withApplicationAt: Bundle.main.bundleURL, configuration: NSWorkspace.OpenConfiguration())
    }

    // MARK: Session

    /// Removes the account `id`; its data stays on this Mac. The notifications and a pending link
    /// of the repos it owned go with it, and once no account is left, every pending link and
    /// notification.
    func removeAccount(_ id: AccountID) throws {
        let owned = Set(controller.ownership.filter { $0.value == id }.keys)
        defer {
            if !controller.isSignedIn {
                clearSession()
            } else if controller.session(for: id) == nil {
                clear(repos: owned)
            }
        }
        try controller.removeAccount(id)
    }

    /// Resets all data, dropping a pending link and the delivered notifications. A reset that
    /// fails after the credentials were deleted has ended the session as well.
    func resetAllData() throws {
        defer {
            if !controller.isSignedIn { clearSession() }
            // The check and the Dock icon follow the settings as they are after the reset, whether
            // it completed or not.
            updates?.setEnabled(controller.settings.checkForUpdates)
            updateDockIcon()
        }
        try controller.resetAllData()
    }

    private func clearSession() {
        navigation = nil
        notifications.removeAll()
    }

    /// Drops the notifications of `repos` and a pending link into one of them.
    private func clear(repos: Set<RepoID>) {
        switch navigation {
        case .item(let key) where repos.contains(key.repo):
            navigation = nil
        case .repo(let id) where repos.contains(id):
            navigation = nil
        default:
            break
        }
        notifications.remove(forRepos: repos)
    }

    /// Where the user grants an organization access for the credential of `session`.
    func grantAccessURL(for session: AccountSession) -> URL {
        let tokens = URL(string: "https://github.com/settings/tokens")!
        guard session.credentialKind == .oauth, isDeviceFlowAvailable else { return tokens }
        return URL(string: "https://github.com/settings/connections/applications/\(oauthClientID)") ?? tokens
    }

    /// An empty value or an unexpanded `$(…)` build setting means "not configured".
    private static func infoValue(_ key: String) -> String {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String else { return "" }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.contains("$(") ? "" : trimmed
    }

    /// Records an assign failure for the main window's alert.
    func reportAssignFailure(_ error: Error, key: ItemKey) {
        let name = controller.repos[key.repo]?.repo.fullName ?? "?"
        assignFailure = AssignFailure(title: "\(name) #\(key.number)", message: Self.message(for: error))
    }

    // MARK: Messages

    static func message(for error: Error) -> String {
        switch error {
        case let error as GitHubError:
            switch error {
            case .unauthorized:
                String(localized: "The token was rejected. Check it and try again.")
            case .forbidden:
                String(localized: "GitHub denied access. Check the permissions of your sign-in.")
            case .rateLimited(let resetAt):
                String(localized: "GitHub's rate limit is reached. Try again at \(time(resetAt)).")
            case .notFound:
                String(localized: "GitHub could not find what Radarix asked for.")
            case .http(let status):
                String(localized: "GitHub answered with error \(status).")
            case .network:
                networkMessage
            case .decoding:
                decodingMessage
            }
        case let error as AssignError:
            switch error {
            case .notPermitted:
                String(localized: "This sign-in can't assign. A fine-grained token needs write access to issues and pull requests.")
            case .noOwner:
                String(localized: "Something went wrong. Try again.")
            }
        case let error as InsightsError:
            switch error {
            case .noOwner:
                String(localized: "Not signed in to an account that watches this repository.")
            }
        case let error as DeviceFlowError:
            switch error {
            case .expired:
                String(localized: "The code has expired. Start the sign-in again.")
            case .denied:
                String(localized: "The sign-in was denied on GitHub.")
            case .notConfigured:
                String(localized: "Sign-in with GitHub is not set up in this build.")
            case .http(let status):
                String(localized: "GitHub answered with error \(status).")
            case .disabled:
                String(localized: "Sign-in with GitHub is turned off for this app.")
            case .badClientID:
                String(localized: "This build's GitHub sign-in is misconfigured. Use a token under Advanced.")
            }
        case is URLError:
            // The device flow talks to github.com directly, so its network errors arrive unmapped.
            networkMessage
        default:
            String(localized: "Something went wrong. Try again.")
        }
    }

    static func message(for issue: OwnerAccessIssue) -> String {
        switch issue {
        case .restricted:
            String(localized: "This organization restricts access. Some repositories may be missing.")
        }
    }

    static func message(for failure: SyncFailure) -> String {
        switch failure {
        case .network: networkMessage
        case .notFound: String(localized: "The repository was not found on GitHub.")
        case .http(let status): String(localized: "GitHub answered with error \(status).")
        case .decoding: decodingMessage
        }
    }

    private static var networkMessage: String {
        String(localized: "GitHub could not be reached. Check your connection.")
    }

    private static var decodingMessage: String {
        String(localized: "GitHub sent an answer Radarix could not read.")
    }

    private static func time(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }
}
