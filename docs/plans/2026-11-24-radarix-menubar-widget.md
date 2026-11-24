# Radarix Menu Bar, Notifications and Widget Implementation Plan (Plan 2 of 3)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Radarix tells the user about new items without opening the app: a menu bar icon with a count and popover, per-repo notifications, desktop widgets in three sizes, open at login, and the final app icon.

**Architecture:** Pure rules go into `RadarixKit` and are tested with `swift test`: tolerant decoding of persisted files, deep links, the widget snapshot, the notification planner. The controller writes a credential-free snapshot to the shared App Group directory after every save. The app target adds an app delegate that owns `AppModel`, a `MenuBarExtra`, a notification service and an open-at-login toggle. A new widget extension target reads only that snapshot.

**Tech Stack:** As Plan 1 (Swift 6, SwiftUI, Observation, Swift Testing, XcodeGen), plus WidgetKit, App Intents, UserNotifications and ServiceManagement. No third-party dependencies.

**Spec:** `docs/specs/2026-11-24-radarix-design.md` (sections Menu bar, Notifications, Widgets, Naming and brand). Follow-ups from Plan 1: `docs/plans/2026-11-24-radarix-core-followups.md`.

**Owner steps (the builder cannot do them):**
- Put the team id in `Config/Local.xcconfig` before checking the widget for real. The widget extension is sandboxed and reads the App Group container, which needs team signing. Ad-hoc builds compile and run, but the widget may show its placeholder only. Changing the signing moves the data directory once, so the app does a fresh baseline after signing in again.
- Look at the icon previews from Task 3 and approve them or ask for changes.
- Manual checks after the plan: menu bar in light and dark mode, notification permission prompt and click, a widget in each size and scope, open at login across a log-out.

## Global Constraints

- Everything in Plan 1's Global Constraints still holds: macOS 15.0, bundle id `dev.noix.radarix`, App Group `$(TeamIdentifierPrefix)dev.noix.radarix`, credentials only in the Keychain, state keyed by numeric ids, English code, UI strings in `en` + `de` ("du"), Conventional Commits with the footer `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- URL scheme **`radarix`**. Deep links: `radarix://item/<repoID>/<number>`, `radarix://repo/<repoID>`, `radarix://open`.
- Widget bundle id **`dev.noix.radarix.widget`**. Its entitlements are `com.apple.security.app-sandbox` plus the same application group. Strings live in `Widget/Resources/Localizable.xcstrings` (`en` + `de`).
- **The snapshot never contains a credential**, an account id, or anything not listed in `WidgetSnapshot`. The snapshot file is `widget-snapshot.json` in the `FileStore` directory.
- **Never silent "seen":**
  - A widget, the menu bar count, the popover appearing and a notification banner never mark anything seen.
  - Marking seen happens only by selecting in the main window, clicking an item in the popover, clicking an item notification, or an explicit mark action.
- Bot display `.hidden`: bot items are not counted in the menu bar, not in the snapshot and never notify.
- Defaults (spec):
  - Notifications are on per repo.
  - New items notify. Updated items and bot items do not.
  - Open at login is off.
- Builder's calls fixed here:
  - **Popover:** shows the newest **10** items.
  - **Notification summary:** applies when **more than 3** notify-worthy items arrive in one repo in one sync.
  - **Widget items:** the snapshot keeps the newest **6** new/updated items per repo.
  - **Dock icon:** always shown in v1.
  - **Login launch:** a launch at login opens no window, and a normal launch opens the main window.

## Review Focus

1. **Files written by Plan 1** (no new keys, no schema version) must still decode, so the user stays signed in and keeps seen state after the update. Pinned in Task 1 (`plan1FilesDecode`).
2. **A first sync of a busy repo, or many new items at once,** must produce one summary per repo, never a flood. The baseline never notifies. Pinned in Task 5 (`manyNewItemsInOneRepoBecomeOneSummary`, `emptyReportPlansNothing`).
3. **Bot display `.hidden`** must keep bots out of the count, the widget and notifications. Pinned in Task 4 (`hiddenBotsExcludedFromSnapshot`) and Task 5 (`hiddenBotsNeverNotify`).
4. **Signed out, needs reauth, reset, or no sync yet:**
   - The widget must show a clear state instead of stale numbers from an earlier session.
   - The menu bar must show the same.
   - Pinned in Task 4 (`signOutWritesSignedOutSnapshot`, `resetRemovesSnapshot`).
5. **A deep link to an item or repo that no longer exists** (unwatched, closed and seen, other account) must open the main window on "All" without crashing or marking anything. Pinned in Task 4 (`malformedLinksAreRejected`) and Task 6 (navigation falls back to `.all`, owner check).

---

## File Structure

```
project.yml                              + widget target, URL scheme, widget embedded in app
App/
  AppDelegate.swift                      NEW: owns AppModel, starts sync at launch, login-launch detection
  RadarixApp.swift                       uses the delegate's model; MenuBarExtra scene; onOpenURL
  AppModel.swift                         + navigation, notification + widget hooks
  LoginItem.swift                        NEW: SMAppService wrapper
  MenuBar/MenuBarLabel.swift             NEW: glyph + count
  MenuBar/MenuBarPopover.swift           NEW: summary, newest items, footer
  Notifications/NotificationService.swift NEW: UNUserNotificationCenter, delegate, click handling
  Main/MainWindow.swift                  reacts to AppModel.navigation
  Settings/GeneralSettings.swift         + open at login, notification permission row
  Settings/AccountSettings.swift         + Reset while signed out
  Settings/RepositorySettings.swift      + restricted-org hint (OAuth)
  Resources/Assets.xcassets              AppIcon, MenuBarGlyph
Widget/
  RadarixWidget.swift                    NEW: WidgetBundle, Widget, TimelineProvider
  ScopeIntent.swift                      NEW: WidgetConfigurationIntent + ScopeEntity
  WidgetViews.swift                      NEW: small / medium / large views
  Resources/Localizable.xcstrings        NEW
  RadarixWidget.entitlements             NEW
docs/design/previews/                    NEW: rendered icon PNGs for owner review
Packages/RadarixKit/Sources/RadarixKit/
  Model/*.swift, Model/Settings.swift    tolerant decoding, schemaVersion
  Auth/DeviceFlow.swift                  error-body mapping
  Auth/CredentialStore.swift             deleteAll()
  Navigation/DeepLink.swift              NEW
  Snapshot/WidgetSnapshot.swift          NEW: snapshot types + summary(for:)
  Notifications/NotificationPlanner.swift NEW
  Persistence/FileStore.swift            + snapshot read/write/remove
  Controller/RadarixController.swift     writes snapshot, follow-up fixes
```

---

### Task 1: Persisted files survive new fields (kit)

**Files:**
- Modify: `Model/Settings.swift`, `Model/Item.swift`, `Model/ItemRecord.swift`, `Filtering/ItemFilter.swift`, `Controller/RadarixController.swift`
- Test: `Tests/RadarixKitTests/SchemaEvolutionTests.swift`, `RadarixControllerTests.swift`. New fixtures `Fixtures/plan1-settings.json` and `Fixtures/plan1-account.json`.

**Interfaces:**
- Produces:
  - `AppSettings.schemaVersion: Int` and `AccountData.schemaVersion: Int`, both with `public static let currentSchemaVersion = 2`. A file without the key decodes as version 1.
  - `public init(new: Int = 0, updated: Int = 0)` on `AttentionCounts`.

- [ ] **Step 1: Capture the fixtures before changing code.** Encode a populated `AppSettings` (non-default layout, interval 600, `lastAccountID`) and a populated `AccountData` with the current Plan 1 code and the `FileStore` encoder (iso8601, sorted keys). The account needs one owner in `.all(excluded:)`, one in `.selected`, `notificationsOff`, one `RepoState` with two records (one `.seen` with `seenAt`, one `.new`) and labels with and without color. Save them as the two fixture files.
- [ ] **Step 2: Write `SchemaEvolutionTests`:**
  - `plan1FilesDecode`: both fixtures decode, field values are equal to what was encoded, and `schemaVersion == 1`.
  - `emptyObjectsUseDefaults`: `{}` decodes to `AppSettings()` and to `WatchConfig()`.
  - `accountWithOnlyRequiredKeysDecodes`: an account with only `accountID` and `login` decodes.
  - `itemWithoutOptionalKeysDecodes`: an `Item` with only `key, kind, title, url, author, createdAt, updatedAt` gets the defaults `status .open`, `isDraft false`, empty lists, `commentCount 0` and an empty excerpt.
  - `unknownKeysAreIgnored`.
  - `savedFilesCarryCurrentVersion`: after a `FileStore` round trip, `schemaVersion == 2`.
- [ ] **Step 3: Add controller tests:**
  - `offlineFallbackSyncKeepsLastSyncAt`: known owners, `owners()` throws `.network`, the engine completes, and `lastSyncAt` stays unchanged.
  - `needsReauthClearsOfflineProblem`.
- [ ] **Step 4: Run** `swift test --package-path Packages/RadarixKit --filter "SchemaEvolution|RadarixController"` → FAIL.
- [ ] **Step 5: Implement.** Give `AppSettings`, `WatchConfig`, `RepoState`, `AccountData`, `ItemRecord` and `Item` a hand-written `init(from:)`.
  - Required keys: `AccountData.accountID/login`, `RepoState.repo`, `ItemRecord.item/attention`, and the seven `Item` keys above.
  - Every other key uses `decodeIfPresent ?? <default>`.
  - Keep the synthesized `encode(to:)` (add `schemaVersion` to the encoded keys).
  - In the controller, set `lastSyncAt` only when the owners call succeeded in that pass, and clear `syncProblem` when auth moves to `.needsReauth`.
- [ ] **Step 6: Run** the filter → PASS, then the full suite → PASS.
- [ ] **Step 7: Commit** `feat(kit): decode persisted files tolerantly and version them`

---

### Task 2: Sign-in hardening before OAuth ships

**Files:**
- Modify: `Auth/DeviceFlow.swift`, `Auth/CredentialStore.swift`, `Controller/RadarixController.swift`, `App/AppModel.swift`, `App/Settings/AccountSettings.swift`, `App/Settings/RepositorySettings.swift`, `Localizable.xcstrings`
- Test: `DeviceFlowTests.swift`, `KeychainCredentialStoreTests.swift`, `RadarixControllerTests.swift`

**Interfaces:**
- Produces:
  - `DeviceFlowError` gains `.disabled` (GitHub `device_flow_disabled`) and `.badClientID` (`incorrect_client_credentials` / `unauthorized_client`).
  - `CredentialStore.deleteAll() throws`, implemented for both stores.
  - `RadarixController.resetAllData()` calls `deleteAll()` and works while signed out.

- [ ] **Step 1: Write the tests:**
  - `startMapsErrorBodyToDeviceFlowError`: 200 with `{"error":"device_flow_disabled"}` → `.disabled`; `incorrect_client_credentials` → `.badClientID`.
  - `waitForTokenMalformedBodyThrowsHTTP`: no raw `DecodingError` escapes.
  - `deleteAllRemovesEveryAccount`: in-memory store, plus a Keychain test with a test-only service name.
  - `resetAllDataRemovesCredentialsOfEveryAccount`: two accounts' credentials stored → none left.
  - `resetWhileSignedOutWipesFiles`.
- [ ] **Step 2: Run** → FAIL. **Step 3: Implement.** `deleteAll` uses `SecItemDelete` with service only and loops until `errSecItemNotFound`.
- [ ] **Step 4: App.**
  - `AppModel.message(for:)` gets a text for each new case:
    - "Sign-in with GitHub is turned off for this app."
    - "This build's GitHub sign-in is misconfigured. Use a token under Advanced."
  - The Account tab shows "Reset all data…" when signed out too, with the same confirmation.
  - In the Repositories tab, every org of an OAuth credential gets a small footnote link: "Missing repositories? Grant access on GitHub", which opens `AppModel.grantAccessURL`.
  - Add en + de strings.
- [ ] **Step 5: Run** the kit suite → PASS, and the app build → `** BUILD SUCCEEDED **` with no new warnings.
- [ ] **Step 6: Commit** `feat: harden sign-in errors and reset before OAuth`

---

### Task 3: App icon and menu bar glyph

**Files:**
- Create: `App/Resources/Assets.xcassets/AppIcon.appiconset/*`, `App/Resources/Assets.xcassets/MenuBarGlyph.imageset/*`, `docs/design/previews/*.png`
- Modify: `docs/design/logo-c2.svg` and `docs/design/menubar-c2.svg` (the refined masters)

**Interfaces:**
- Produces: an image asset named `MenuBarGlyph`, with template rendering and preserved vector data. Task 7 uses it as `Image("MenuBarGlyph")`.

- [ ] **Step 1: Refine the masters.** The masters follow spec direction C2: navy squircle, a faint cyan ring, three connected cyan nodes, and the newest node in amber.
  - **Colors:** cyan `#00B8C8`, amber `#F5A524`, ink `#0B1524`.
  - **App icon:** follow the macOS icon grid, an 824 px squircle body on a 1024 canvas.
  - **Glyph:** must read at 16 pt. Use strokes of at least 1.25 pt, no detail under 1 pt, and a single color (black, alpha only).
- [ ] **Step 2: Render the app icon** from `logo-c2.svg` with `rsvg-convert` (installed at `/opt/homebrew/bin`) into the ten macOS sizes: 16, 32, 128, 256 and 512, each at @1x and @2x. Write `Contents.json`. Do not commit a render script or add a dependency.
- [ ] **Step 3: Add the glyph** as an SVG in `MenuBarGlyph.imageset`. In `Contents.json`, set `"template-rendering-intent": "template"` and `"preserves-vector-representation": true`.
- [ ] **Step 4: Owner previews.** Write `docs/design/previews/app-icon-512.png`, `app-icon-32.png`, `menubar-light.png` and `menubar-dark.png` (the glyph at 16 pt and 32 px on `#ECECEC` and `#1E1E1E`).
- [ ] **Step 5: Run** `xcodegen generate && xcodebuild … build`. Expect `** BUILD SUCCEEDED **` with no asset catalog warnings, and confirm that `Radarix.app/Contents/Resources/AppIcon.icns` (or `Assets.car`) contains the icon.
- [ ] **Step 6: Commit** `feat(app): add the app icon and menu bar glyph`

---

### Task 4: Deep links and the widget snapshot (kit)

**Files:**
- Create: `Navigation/DeepLink.swift`, `Snapshot/WidgetSnapshot.swift`
- Modify: `Persistence/FileStore.swift`, `Controller/RadarixController.swift`
- Test: `DeepLinkTests.swift`, `WidgetSnapshotTests.swift`, `RadarixControllerTests.swift`

**Interfaces:**
- Produces:

```swift
public enum DeepLink: Sendable, Equatable {
    case item(ItemKey), repo(RepoID), main
    public init?(url: URL)          // scheme "radarix" only
    public var url: URL
}

public enum WidgetScope: Sendable, Hashable, Codable { case all, owner(String), repo(RepoID) }

public struct WidgetSnapshot: Codable, Sendable, Equatable {
    public enum Status: String, Codable, Sendable { case ok, needsReauth, signedOut }
    public struct ItemEntry: Codable, Sendable, Equatable, Identifiable {
        public let key: ItemKey; public let kind: ItemKind; public let title: String
        public let attention: Attention; public let updatedAt: Date; public let isDraft: Bool
        public let botName: String?          // Actor.botDisplayName, nil for humans
        public var id: ItemKey { key }
    }
    public struct RepoEntry: Codable, Sendable, Equatable, Identifiable {
        public let id: RepoID; public let owner: String; public let name: String
        public let newCount: Int; public let updatedCount: Int
        public let items: [ItemEntry]        // newest 6 new/updated, updatedAt desc
        public var fullName: String { "\(owner)/\(name)" }
    }
    public struct Summary: Sendable, Equatable {
        public let newCount: Int; public let updatedCount: Int
        public let repos: [RepoEntry]        // total desc, then fullName
        public let items: [ItemEntry]        // merged, updatedAt desc, then key
        public var busiestRepo: RepoEntry? { repos.first(where: { $0.newCount + $0.updatedCount > 0 }) }
    }
    public static let itemsPerRepo = 6
    public var status: Status
    public var login: String?
    public var syncedAt: Date?
    public var repos: [RepoEntry]
    public static let signedOut: WidgetSnapshot
    public static func make(account: AccountData, settings: AppSettings, auth: AuthState, syncedAt: Date?) -> WidgetSnapshot
    public func summary(for scope: WidgetScope) -> Summary
    public var owners: [String] { get }      // distinct, sorted, for the widget's scope picker
}
```

- `FileStore`: `saveSnapshot(_:) throws`, `loadSnapshot() throws -> WidgetSnapshot?`, `removeSnapshot() throws`.
- `RadarixController`:
  - Writes `WidgetSnapshot.make(…)` after every account save, after `updateSettings`, and on `signOut`. It writes `.signedOut` there and on `restoreSession`'s signed-out path.
  - Then calls `@ObservationIgnored public var onSnapshotWritten: (() -> Void)?`.
  - `resetAllData()` removes the file, and `resetAll()` already removes the directory.

- [ ] **Step 1: Write `DeepLinkTests`:**
  - `roundTripsEveryCase`.
  - `malformedLinksAreRejected`: wrong scheme, `item/abc/1`, `item/1`, `repo/`, extra segments, and negative numbers → `nil`.
- [ ] **Step 2: Write `WidgetSnapshotTests`:**
  - `countsOnlyListedNewAndUpdated`: seen and closed-seen items are excluded.
  - `keepsNewestSixPerRepo`.
  - `hiddenBotsExcludedFromSnapshot`: in `.hidden` mode, bot items are absent and not counted. In `.badge` mode they are present with `botName == "Dependabot"`.
  - `summaryForOwnerAndRepoScopes`.
  - `busiestRepoIsLargestTotal`: ties are broken by `fullName`.
  - `snapshotJSONHasOnlyKnownKeys`: the encoded JSON's key set (recursive) equals the fields declared above. This guards against a credential ever leaking in.
  - `unwatchedRepoExcluded`.
- [ ] **Step 3: Add controller tests:**
  - `syncWritesSnapshotAndNotifies`: the file exists after sync and `onSnapshotWritten` was called.
  - `markSeenUpdatesSnapshot`.
  - `signOutWritesSignedOutSnapshot`.
  - `resetRemovesSnapshot`.
  - `needsReauthSnapshotStatus`.
- [ ] **Step 4: Run** → FAIL. **Step 5: Implement.** Selection reuses `ItemStateEngine.isListed` and the attention filter. Bots are dropped only when the mode is `.hidden`.
- [ ] **Step 6: Run** → PASS, then the full suite → PASS.
- [ ] **Step 7: Commit** `feat(kit): add deep links and the widget snapshot`

---

### Task 5: Notification planner (kit)

**Files:**
- Create: `Notifications/NotificationPlanner.swift`
- Test: `NotificationPlannerTests.swift`

**Interfaces:**
- Produces:

```swift
public struct PlannedNotification: Sendable, Equatable {
    public enum Content: Sendable, Equatable {
        case item(Item, Attention)                                   // .new or .updated
        case summary(repo: RepoRef, newCount: Int, updatedCount: Int)
    }
    public let id: String        // "item-<repoID>-<number>" or "repo-<repoID>"
    public let content: Content
}
public enum NotificationPlanner {
    public static let summaryThreshold = 3
    public static func plan(_ report: SyncReport, account: AccountData, settings: AppSettings) -> [PlannedNotification]
}
```

Rules:
- Candidates are `report.newItems`, plus `report.updatedItems` when `settings.notifyUpdated` is on.
- Drop items in a repo listed in `account.watch.notificationsOff`, or in a repo that is no longer in `account.repos`.
- Drop bot items unless `settings.notifyBots` is on. Always drop them when `botDisplay == .hidden`.
- Group by repo. More than `summaryThreshold` items → one `.summary`. Otherwise one `.item` each.
- Order: by repo `fullName`, then `updatedAt` descending.

- [ ] **Step 1: Write the tests:**
  - `newItemNotifies`.
  - `updatedNotifiesOnlyWhenEnabled`.
  - `repoWithNotificationsOffIsSilent`.
  - `botsSilentByDefault`.
  - `botsNotifyWhenEnabled`.
  - `hiddenBotsNeverNotify`: even with `notifyBots` on.
  - `manyNewItemsInOneRepoBecomeOneSummary`: 4 new → one summary with `newCount 4`. 3 new → three items.
  - `summaryCountsUpdatedSeparately`.
  - `emptyReportPlansNothing`: a baseline report has no `newItems`.
  - `idsAreStable`.
- [ ] **Step 2: Run** → FAIL. **Step 3: Implement.** **Step 4: Run** → PASS, then the full suite → PASS.
- [ ] **Step 5: Commit** `feat(kit): plan notifications from a sync report`

---

### Task 6: App lifecycle, deep-link navigation and open at login

**Files:**
- Create: `App/AppDelegate.swift`, `App/LoginItem.swift`
- Modify: `App/RadarixApp.swift`, `App/AppModel.swift`, `App/Main/MainWindow.swift`, `App/Main/SidebarLayout.swift`, `App/Settings/GeneralSettings.swift`, `project.yml`, `Localizable.xcstrings`

**Interfaces:**
- Consumes: `DeepLink` from Task 4.
- Produces:
  - `AppDelegate: NSObject, NSApplicationDelegate` with `let model = AppModel()`. `RadarixApp` uses `@NSApplicationDelegateAdaptor` and reads `appDelegate.model`, which replaces the `@State` model.
  - `AppModel.launchedAtLogin: Bool`, set by the delegate before the scenes appear.
  - `AppModel.navigation: DeepLink?`, which the main window consumes and sets back to `nil`.
  - `AppModel.open(_ link: DeepLink)` = `NSWorkspace.shared.open(link.url)`. The system routes the link back to the main `WindowGroup`, which opens a window if none is open. That way kit-free callers (notification clicks, Task 8) need no `openWindow`.
  - `LoginItem.isEnabled: Bool`, `LoginItem.setEnabled(_:) throws` and `LoginItem.needsApproval: Bool`, wrapping `SMAppService.mainApp`.

- [ ] **Step 1: Launch behavior.**
  - `applicationDidFinishLaunching` calls `model.start()`. The `.onAppear { model.start() }` calls are removed, so syncing runs with no window open.
  - `applicationShouldTerminateAfterLastWindowClosed` → `false`.
  - In `applicationWillFinishLaunching`, set `launchedAtLogin` from `NSAppleEventManager.shared().currentAppleEvent?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem`.
  - The main window still opens at every launch in this task. Task 7 suppresses it for login launches.
- [ ] **Step 2: URL scheme.**
  - Register `radarix` under `CFBundleURLTypes` in `project.yml` (`info.properties`).
  - While in `project.yml`, drop the overlap between `GENERATE_INFOPLIST_FILE` and the committed `App/Info.plist` noted in Plan 1: keep one source.
  - The `WindowGroup(id: "main")` gets `.handlesExternalEvents(matching: ["radarix"])`. `MainWindow`'s `.onOpenURL` parses `DeepLink(url:)`, activates the app and sets `model.navigation`. An invalid link is ignored.
- [ ] **Step 3: Navigation in the main window.**
  - `.repo(id)` selects that repo in the sidebar, or `.all` if it is not watched.
  - `.item(key)` selects that repo plus the item, and selecting marks it seen as today.
  - If the item is not listed, select its repo, or `.all`. Select nothing and mark nothing.
  - In the grouped layout, `.repo` only scrolls to the repo section.
  - `.main` only activates the window.
- [ ] **Step 4: Open at login.**
  - Add a General tab toggle, "Open at login". `LoginItem.isEnabled` is the source of truth, and `settings.openAtLogin` mirrors it.
  - On error, show `AppModel.message(for:)` inline.
  - When approval is needed, show "Allow Radarix in System Settings → Login Items." with a button that calls `SMAppService.openSystemSettingsLoginItems()`.
  - Add en + de strings.
- [ ] **Step 5: Verify (Ruling R12 from Plan 1).**
  - Build → `** BUILD SUCCEEDED **` with no new warnings.
  - Smoke test: launch, `pgrep -x Radarix`, then `open "radarix://repo/1"` and confirm it does not crash, then quit.
  - The owner checks login launch and real deep links.
- [ ] **Step 6: Commit** `feat(app): keep running in the background, handle deep links, open at login`

---

### Task 7: Menu bar extra

**Files:**
- Create: `App/MenuBar/MenuBarLabel.swift`, `App/MenuBar/MenuBarPopover.swift`
- Modify: `App/RadarixApp.swift`, `Localizable.xcstrings`

**Interfaces:**
- Consumes: `MenuBarGlyph` (Task 3), `AppModel.open(_:)` (Task 6), and from the controller: `counts(in: nil)`, `records(in: nil)`, `markSeen`, `markAllSeen`, `refresh`, `auth`, `syncProblem`, `lastSyncAt`, `isSyncing`.

- [ ] **Step 0: Login launch without a window.** The `WindowGroup(id: "main")` gets `.defaultLaunchBehavior(.suppressed)`. `MenuBarLabel` exists from launch. Its `.task` calls `openWindow(id: "main")` once per launch, unless `model.launchedAtLogin` is true. Guard it with a flag in `AppModel`.
- [ ] **Step 1: The `MenuBarExtra` scene** uses `.menuBarExtraStyle(.window)`. The label is `Image("MenuBarGlyph")` plus `Text(count)` when `counts(in: nil).total > 0`. When `auth` is `.needsReauth`, the label shows `!` instead of the count. Use `monospacedDigit`. The accessibility label is "Radarix, %lld new or updated".
- [ ] **Step 2: Popover content, about 340 pt wide:**
  - **Header:** "%lld new · %lld updated" (plural variations), with a refresh button that shows a spinner while `isSyncing`, and "Synced %@" in relative style.
  - **State rows:**
    - Signed out: "Sign in to GitHub" opens Settings.
    - Needs reauth: "Sign in again" opens Settings.
    - Offline: "Can't reach GitHub. Showing saved data."
    - Rate limited: reuse the existing string.
  - **Items:** the newest 10 from `ItemFilter.visible(records(in: nil), filter: FilterSet(), viewer: login, scope: settings.botDisplay == .hidden ? .humans : .all)`. The list must match the label count, so bots grouped in the main window still appear here. Each row shows the attention dot (the colors from `ItemRow`), the kind icon, a one-line title and `owner/name`. A click opens the item URL and then calls `markSeen`.
  - **Empty state:** "Nothing new."
  - **Footer:** "Mark all as seen", "Open Radarix" (`model.open(.main)`), "Settings…" (`openSettings`), and "Quit Radarix".
- [ ] **Step 3: Rules.** Opening the popover marks nothing. Reuse `ItemRow`'s color extension instead of redefining the colors. Add a `#Preview` fed with `PreviewSamples`.
- [ ] **Step 4: Verify.** Build and smoke test. The owner checks the popover in light and dark mode.
- [ ] **Step 5: Commit** `feat(app): add the menu bar extra`

---

### Task 8: Notifications in the app

**Files:**
- Create: `App/Notifications/NotificationService.swift`
- Modify: `App/AppModel.swift`, `App/AppDelegate.swift`, `App/Settings/GeneralSettings.swift`, `Localizable.xcstrings`

**Interfaces:**
- Consumes: `NotificationPlanner.plan`, `PlannedNotification` (Task 5), `DeepLink` (Task 4), and `controller.onSyncReport`.
- Produces:
  - `NotificationService` (`@MainActor`, `UNUserNotificationCenterDelegate`) with `requestAuthorizationIfNeeded()`, `post(_ planned: [PlannedNotification])`, `authorizationDenied: Bool` (observable), and an `onOpen: (NotificationTarget) -> Void` callback.
  - `NotificationTarget` is `.item(ItemKey, URL)` or `.repo(RepoID)`.

- [ ] **Step 1: Hooks.**
  - `AppModel` sets `controller.onSyncReport` to post `NotificationPlanner.plan(report, account:, settings:)`.
  - `controller.onSnapshotWritten` calls `WidgetCenter.shared.reloadAllTimelines()`. Import WidgetKit in the app.
  - Make it one assignment per closure in `AppModel.init`, so nothing else overwrites them.
  - Authorization is requested with `[.alert, .sound]` when `auth` first becomes `.signedIn` in a launch.
- [ ] **Step 2: Content.**
  - **Item notification:**
    - The title is `owner/name`.
    - The subtitle is "New pull request", "New issue", "Updated pull request" or "Updated issue".
    - The body is the item title.
    - `threadIdentifier` is the repo id. The identifier is `planned.id`.
    - `userInfo` holds `url`, `repo` and `number`.
  - **Summary:** the title is `owner/name`, and the body is "%lld new items" and/or "%lld updated items" (plurals). The `userInfo` deep link is `radarix://repo/<id>`.
  - Banners do nothing else. `willPresent` returns `[.banner, .list, .sound]`, so notifications also show while the app is frontmost.
- [ ] **Step 3: Click.** The `didReceive` delegate handles the click:
  - An item click opens the URL with `NSWorkspace` and calls `markSeen(key)`.
  - A summary click calls `model.open(.repo(id))`, which marks nothing.
  - The delegate is set in `applicationWillFinishLaunching`, so clicks that launch the app are handled.
- [ ] **Step 4: Settings.** When `authorizationDenied` is true, the General tab shows "Notifications are turned off for Radarix in System Settings." with a button that opens `x-apple.systempreferences:com.apple.Notifications-Settings.extension`. Add en + de strings.
- [ ] **Step 5: Verify.** Build and smoke test. The owner checks the prompt, a real notification, and the click.
- [ ] **Step 6: Commit** `feat(app): post notifications for new items`

---

### Task 9: Widget extension

**Files:**
- Create: `Widget/RadarixWidget.swift`, `Widget/ScopeIntent.swift`, `Widget/WidgetViews.swift`, `Widget/Resources/Localizable.xcstrings`, `Widget/RadarixWidget.entitlements`
- Modify: `project.yml`

**Interfaces:**
- Consumes: `WidgetSnapshot`, `WidgetScope`, `DeepLink` (Task 4), `FileStore.defaultDirectory(appGroup:)` and `loadSnapshot()`.
- Produces: the widget kind `"dev.noix.radarix.widget.overview"`.

- [ ] **Step 1: Target.**
  - Add `RadarixWidget` to `project.yml`:
    - type `app-extension`, platform macOS
    - depends on `RadarixKit`
    - `NSExtension.NSExtensionPointIdentifier = com.apple.widgetkit-extension`
    - the Info key `RadarixAppGroup = $(TeamIdentifierPrefix)dev.noix.radarix`
    - bundle id `dev.noix.radarix.widget`
    - entitlements: sandbox and the app group
  - The app target embeds it (`dependencies: - target: RadarixWidget, embed: true`).
- [ ] **Step 2: Configuration.**
  - `ScopeIntent: WidgetConfigurationIntent` has `@Parameter(title: "Show") var scope: ScopeEntity?`, where `nil` means "All repositories".
  - `ScopeEntity: AppEntity` has a String id: `all`, `owner:<login>` or `repo:<id>`.
  - Its `EntityQuery` lists "All repositories", each of `snapshot.owners`, then each repo `fullName`, read from the snapshot.
  - The entity maps to `WidgetScope`. An entity whose repo disappeared falls back to `.all`.
- [ ] **Step 3: Provider.**
  - Use `AppIntentTimelineProvider`. Each `timeline` reads the snapshot fresh, as one entry with policy `.never`. The app reloads after every snapshot write.
  - `placeholder` uses sample data.
  - A snapshot that is missing or `.signedOut` shows "Open Radarix to sign in." `.needsReauth` shows "Sign in again in Radarix."
  - Relative times use `Text(date, style: .relative)`.
- [ ] **Step 4: Views.**
  - **Small:**
    - the new and updated counts (blue `#2F7CF6`, amber `#F5A524`, with ink `#0B1524` text on amber)
    - the busiest repo's name
    - `widgetURL` points to `.repo` of the busiest repo, or `.main` if there is none
  - **Medium:** a summary line, then the newest 4 items, each a `Link` to `.item(key)`.
  - **Large:** the summary, up to 4 repo rows with their counts, each linking to `.repo`, then the newest 5 items as links.
  - **Empty state:** "Nothing new."
  - Bot items show their `botName` badge.
  - The widget never writes anything. Add `#Preview(as: .systemSmall/.systemMedium/.systemLarge)` with sample snapshots.
- [ ] **Step 5: Strings.** Every widget string goes in `Widget/Resources/Localizable.xcstrings` in en + de, including the intent and parameter titles as `LocalizedStringResource`.
- [ ] **Step 6: Verify.**
  - `xcodegen generate && xcodebuild … build` → `** BUILD SUCCEEDED **` with no new warnings.
  - `Radarix.app/Contents/PlugIns/RadarixWidget.appex` exists.
  - `codesign -d --entitlements - <appex>` shows the sandbox and the group.
  - The owner adds the widget with team signing.
- [ ] **Step 7: Commit** `feat(widget): add the overview widget in three sizes`
