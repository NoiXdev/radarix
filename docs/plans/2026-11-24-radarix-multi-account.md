# Radarix several accounts Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Several GitHub accounts in one Radarix, merged into one inbox, failing independently, each repo shown once.

**Architecture:** `RadarixController` stays the app's single entry point but becomes the workspace: it holds one `AccountSession` per account (credential, API, `AccountData`, sync state), the global `AppSettings`, repo ownership, merged queries, the widget snapshot and the scheduler. A sync pass resolves repo lists per account in account order, computes ownership (earliest account wins), then syncs items for all healthy sessions concurrently. "Me" is the set of logins of all accounts.

**Tech Stack:** Swift 6 (strict concurrency), SwiftUI, Observation, Swift Testing, WidgetKit, XcodeGen (`/opt/homebrew/bin/xcodegen`), local package `Packages/RadarixKit`.

**Spec:** `docs/specs/2026-11-24-radarix-multi-account-design.md` (extends `docs/specs/2026-11-24-radarix-design.md`).

## Global Constraints

- Swift 6 strict concurrency; kit logic lives in `RadarixKit` and is tested with Swift Testing. New logic comes with tests. All existing tests stay green (189 at plan time) or are moved/adapted, never deleted without a replacement.
- Kit tests: `cd Packages/RadarixKit && swift test`. App build: `/opt/homebrew/bin/xcodegen generate -q && xcodebuild -project Radarix.xcodeproj -scheme Radarix -configuration Debug -derivedDataPath DerivedData build`, expected `** BUILD SUCCEEDED **` with no new warnings.
- Never-silent-"seen": nothing becomes seen by being visible in a widget, the menu bar list or a notification banner.
- Credentials only in the Keychain, one item per account id (unchanged `CredentialStore`).
- Persisted files decode tolerantly (`decodeIfPresent` + defaults); saving writes the current schema version.
- Code, comments, commits in English. UI strings go through `App/Resources/Localizable.xcstrings` (and `Widget/Resources/Localizable.xcstrings` for the widget) with a German translation for every new string.
- Conventional Commits, footer `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. No push.
- Account order = `AppSettings.accountIDs` order = order added (oldest first). It decides repo ownership and sidebar order.
- Accounts are labelled by GitHub login only.
- One global sync interval; all accounts sync in the same pass.

## Review Focus

1. **Upgrade from a single-account install** (settings v2 with `lastAccountID`): after launch the user is still signed in with the same data and seen state, no sign-in prompt. → Task 1 (decode) and Task 5 (`upgradeFromV2KeepsSession`).
2. **One account 401s while the other syncs**: the healthy account's new items arrive, the broken account's items stay listed, the merged count includes both. → Task 5 (`reauthAccountDoesNotStopOthers`).
3. **A repo visible to both accounts**: listed once, counted once, one notification, mark-seen sticks. → Task 5 (`sharedRepoListedOnce`).
4. **Removing the account that owns a shared repo**: the other account takes over with a baseline, so no "new" items and no notifications for existing issues. → Task 5 (`takeoverBaselinesWithoutNewItems`).
5. **Own activity from the other account**: a comment by the work login on a repo synced via the private account does not make the item "updated". → Task 2 (`otherAccountLoginCountsAsViewer`) and Task 5 (`ownActivityFromOtherAccountStaysSeen`).

---

### Task 1: Persisted model for several accounts

**Files:**
- Modify: `Packages/RadarixKit/Sources/RadarixKit/Model/Settings.swift`
- Create: `Packages/RadarixKit/Tests/RadarixKitTests/Fixtures/plan2-settings.json` (a v2 settings file with `lastAccountID: 42`, copy the shape of `plan1-settings.json` with `"schemaVersion": 2`)
- Test: `Packages/RadarixKit/Tests/RadarixKitTests/SchemaEvolutionTests.swift`, `FileStoreTests.swift`

**Interfaces:**
- Produces:
  - `AppSettings.currentSchemaVersion == 3`; `AppSettings.accountIDs: [AccountID]` (default `[]`). `lastAccountID` is removed from the public API; decoding maps a v1/v2 `lastAccountID` to `accountIDs = [id]`. Encoding writes `accountIDs` and never `lastAccountID`.
  - `AccountData.currentSchemaVersion == 3`; `AccountData.available: [String: [RepoRef]]` (default `[:]`): the repo list of every active owner from the last resolution, keyed by owner login. Persisted so ownership and Settings work before the first sync after launch.

- [ ] **Step 1: Write the failing tests** in `SchemaEvolutionTests`:
  - `v2SettingsMapLastAccountToAccountList`: decode `plan2-settings.json` → `accountIDs == [AccountID(rawValue: 42)]`, other fields as in the fixture.
  - `plan1SettingsMapLastAccountToAccountList`: same for `plan1-settings.json`.
  - `settingsWithoutAccountDecodeToEmptyList`: `{}` → `accountIDs == []`, `schemaVersion == 1`.
  - `settingsEncodeAccountIDsNotLastAccountID`: encode `AppSettings` with `accountIDs = [1, 2]` → JSON object has key `accountIDs` == `[1, 2]`, has no key `lastAccountID`, `schemaVersion == 3`.
  - `accountWithoutAvailableDecodesEmpty`: decode `plan1-account.json` → `available == [:]`.
  - In `FileStoreTests.accountRoundTripsAndIsKeyedByID`, set `a.available = ["o": [repo]]` before saving so the round trip covers it.
- [ ] **Step 2: Run** `cd Packages/RadarixKit && swift test --filter "SchemaEvolutionTests|FileStoreTests"` → FAIL (no member `accountIDs` / `available`).
- [ ] **Step 3: Implement** in `Settings.swift`. Keep the private legacy key `lastAccountID` in `CodingKeys` for decoding only. Fix every compile error in the kit that used `lastAccountID` by using `accountIDs.first` / `accountIDs = [id]` so the single-account behaviour is unchanged (the controller changes properly in Task 5). Update the `Harness.seed` in `RadarixControllerTests` to `settings.accountIDs = [account.accountID]`.
- [ ] **Step 4: Run** `swift test` → all pass.
- [ ] **Step 5: Commit** `feat(kit): persist an account list and resolved repos`

---

### Task 2: "Me" is a set of logins

**Files:**
- Create: `Packages/RadarixKit/Sources/RadarixKit/Model/ViewerLogins.swift`
- Modify: `State/ItemStateEngine.swift`, `Filtering/ItemFilter.swift`, `GitHub/ActivityProbe.swift`, `GitHub/GitHubAPI.swift` (protocol + `GitHubClient` conformance), `Sync/SyncEngine.swift`, `Tests/.../Support/StubGitHubAPI.swift`
- Test: `ItemStateEngineTests.swift`, `ItemFilterTests.swift`, `ActivityProbeTests.swift`, `SyncEngineTests.swift`

**Interfaces:**
- Produces:
  - `public struct ViewerLogins: Sendable, Equatable { public init(_ logins: some Sequence<String>); public func contains(_ login: String) -> Bool }`, case-insensitive (store lowercased).
  - `ItemStateEngine.apply(fetched:previous:viewers: ViewerLogins, otherActivity:)` (was `viewer: String`). An item authored by any viewer login starts as seen.
  - `ItemFilter.visible(_:filter:viewers: ViewerLogins, scope:)`: "Assigned to me" / "Review requested from me" match any viewer login.
  - `ActivityProbe.hasOtherActivity(in:since:viewers: ViewerLogins, itemAuthorIsViewer:)`.
  - `GitHubAPI.hasOtherActivity(on:in:since:viewers: ViewerLogins) async throws -> Bool`.
  - `SyncEngine` takes `viewers: ViewerLogins` where it used `account.login` (Task 3 sets the final signature; here add a `viewers:` parameter to the existing `sync(_:owners:previousAvailable:)`).

- [ ] **Step 1: Write the failing tests**:
  - `ViewerLogins` (in `ItemFilterTests` or a new `ViewerLoginsTests.swift`): `ViewerLogins(["Alice", "bob"]).contains("alice") && .contains("BOB") && !.contains("carol")`.
  - `ItemStateEngineTests.otherAccountLoginCountsAsViewer`: a new item authored by `"work"` with `viewers: ["me", "work"]` → `.seen`.
  - `ItemFilterTests.assignedToMeMatchesAnyAccount`: item assigned to `"work"`, filter `assignedToMe`, viewers `["me", "work"]` → visible; viewers `["me"]` → not visible.
  - `ActivityProbeTests.otherAccountActivityIsNotOther`: a comment by `"work"` after `since` with viewers `["me", "work"]` → `false`.
  - Adapt existing call sites in tests to pass `ViewerLogins(["<old viewer>"])`.
- [ ] **Step 2: Run** `swift test` → FAIL (compile).
- [ ] **Step 3: Implement** the type and the signature changes. `GitHubClient.hasOtherActivity` computes `itemAuthorIsViewer` as `viewers.contains(item.author.login)`. The controller passes `ViewerLogins([account.login])` for now.
- [ ] **Step 4: Run** `swift test` → all pass.
- [ ] **Step 5: Commit** `refactor(kit): treat every account login as the viewer`

---

### Task 3: Two-phase sync and repo ownership

**Files:**
- Create: `Packages/RadarixKit/Sources/RadarixKit/Sync/RepoOwnership.swift`
- Modify: `Sync/SyncEngine.swift`
- Test: `SyncEngineTests.swift`, create `RepoOwnershipTests.swift`

**Interfaces:**
- Consumes: `ViewerLogins` (Task 2), `AccountData.available` (Task 1).
- Produces:
  - `public enum SyncStop: Sendable, Equatable { case reauth, rateLimited(until: Date), cancelled }`
  - `public struct Resolution: Sendable, Equatable { public var available: [String: [RepoRef]]; public var unknownOwners: Set<String>; public var ownerIssues: [String: OwnerAccessIssue]; public var stop: SyncStop? }`
  - `SyncEngine.resolve(_ account: AccountData, owners: [OwnerRef]) async -> Resolution`: fetches the repo list of every owner not `.off`; a `.notModified` or failed list keeps `account.available[owner]`; `available` contains only active owners; `unknownOwners` = active owners with no list at all; restricted-org issues as today; a reauth/rate-limit/cancel stop ends the loop and is returned in `stop`.
  - `SyncEngine.sync(_ account: AccountData, owned: [RepoRef], keep: Set<RepoID>, viewers: ViewerLogins) async -> (AccountData, SyncReport)`: syncs exactly `owned` (in the given order); drops (and `forgetConditionalState`s) every stored `RepoState` whose id is neither in `owned` nor in `keep`; `keep` states stay untouched. Report fields as today except `availableRepos`/`ownerIssues`, which the caller fills from the `Resolution`.
  - `public enum RepoOwnership { public static func assign(_ watched: [(AccountID, [RepoRef])]) -> [RepoID: AccountID] }`: input in account order; the first account listing a repo id owns it.
  - The old `sync(_:owners:previousAvailable:)` is removed; the controller in this task calls `resolve` then `sync` with `owned = RepoResolver.watched(config:available:)`, `keep` = ids of stored states whose `repo.owner` is in `resolution.unknownOwners`, and stores `resolution.available` into `account.available` (replacing the in-memory `availableRepos` source; `availableRepos` now reads `account?.available ?? [:]`).

- [ ] **Step 1: Write the failing tests**:
  - `RepoOwnershipTests`: `firstAccountWins` (repo 1 in accounts 10 and 20 → owner 10; repo 2 only in 20 → 20); `emptyInputGivesEmptyMap`; `orderNotIdDecides` (input order `[(20, [r1]), (10, [r1])]` → 20).
  - `SyncEngineTests.resolveKeepsPreviousListOnFailure`: `account.available = ["o": [repoA]]`, repositories(of: o) throws `.network` → `resolution.available["o"] == [repoA]`, `unknownOwners` empty.
  - `resolveReportsUnknownOwnerWithoutList`: same failure with `available == [:]` → `unknownOwners == ["o"]`.
  - `resolveStopsOnReauth`: repositories throws `.unauthorized` → `stop == .reauth`.
  - `syncDropsStatesNotOwnedOrKept`: stored states for repos 1, 2, 3; `owned = [repo1]`, `keep = [3]` → result has 1 and 3, not 2; `forgetConditionalState` was called for 2 only.
  - Move every existing `SyncEngineTests` case to the new two calls (resolve then sync with `owned = RepoResolver.watched(...)`); their assertions stay.
- [ ] **Step 2: Run** `swift test --filter "SyncEngineTests|RepoOwnershipTests"` → FAIL.
- [ ] **Step 3: Implement** the split, `RepoOwnership`, and the controller call site as described above.
- [ ] **Step 4: Run** `swift test` → all pass (the 36 controller tests included).
- [ ] **Step 5: Commit** `refactor(kit): split sync into resolve and item phases, add repo ownership`

---

### Task 4: Extract `AccountSession`

Pure refactor: the controller still has exactly one account, all behaviour and tests unchanged.

**Files:**
- Create: `Packages/RadarixKit/Sources/RadarixKit/Controller/AccountSession.swift`
- Modify: `Controller/RadarixController.swift`
- Test: `RadarixControllerTests.swift` (must pass unchanged, apart from compile fixes in the harness)

**Interfaces:**
- Produces (`@MainActor @Observable public final class AccountSession`):
  - Read-only state: `accountID: AccountID`, `account: AccountData`, `login: String` (= `account.login`), `credentialKind: CredentialKind`, `auth: SessionAuth` where `public enum SessionAuth: Sendable, Equatable { case ok, needsReauth }`, `owners: [OwnerRef]`, `lastReport: SyncReport?`, `lastSyncAt: Date?`, `syncProblem: SyncProblem?`, `rateLimitedUntil: Date?`, `isSyncing: Bool`.
  - `init(account: AccountData, credential: Credential, api: GitHubAPI, store: FileStore, now: @escaping @Sendable () -> Date)`
  - `func resolve() async -> Bool`: owners call + `SyncEngine.resolve`; maps errors exactly as the controller's `sync` does today (401 → `auth = .needsReauth`, `syncProblem = nil`; rate limit → `syncProblem = .rateLimited`; network → `.offline` and fall back to known owners); returns false when this session must not sync items in this pass (needs reauth, rate limited, no owners known, cancelled). Persists `account.available`.
  - `unknownOwners: Set<String>`: from the last `resolve()` that ran `SyncEngine.resolve` (empty before).
  - `func watchedRepos() -> [RepoRef]`: `RepoResolver.watched(config: account.watch, available: account.available)`.
  - `func syncItems(owned: [RepoRef], keep: Set<RepoID>, viewers: ViewerLogins) async -> SyncReport?`: runs `SyncEngine.sync`, merges watch changes and the journal exactly as today, sets `lastSyncAt`/`syncProblem`/`auth` per today's rules, saves the account; nil when the session ended meanwhile.
  - Marks: `markSeen(_:)`, `markUnseen(_:)`, `markRepoSeen(_:)`, `markAllSeen()` with today's journal semantics.
  - Watch: `setOwnerMode(_:for:)`, `setNotifications(_:for:)`, `setShowArchived(_:)`; each saves and calls `onWatchChanged` (`@ObservationIgnored var onWatchChanged: (() -> Void)?`), which the controller answers with `requestRefresh()`.
  - `@ObservationIgnored var onSaved: (() -> Void)?`, called after every account save, so the controller rewrites the widget snapshot.
  - `func end()`: cancels, bumps its generation so running work is discarded.
- `RadarixController` keeps its whole public API in this task and forwards to `private var session: AccountSession?`.

- [ ] **Step 1: Run** `swift test` → green baseline (record the count).
- [ ] **Step 2: Move** the per-account state and logic into `AccountSession` as listed; the controller keeps settings, scheduler, `requestRefresh`/`followUpRefresh`, snapshot writing, sign-in/out/reset.
- [ ] **Step 3: Run** `swift test` → same count, all pass. Build the app (command in Global Constraints) → succeeds without source changes in `App/`.
- [ ] **Step 4: Commit** `refactor(kit): move per-account sync state into AccountSession`

---

### Task 5: The workspace: several sessions

**Files:**
- Modify: `Controller/RadarixController.swift`, `Controller/AccountSession.swift`
- Test: `RadarixControllerTests.swift`; create `MultiAccountTests.swift`; `Support/StubGitHubAPI.swift` as needed

**Interfaces:**
- Consumes: Tasks 1–4.
- Produces (`RadarixController` public API; old single-account members `auth`, `account`, `credentialKind`, `owners`, `availableRepos`, `lastReport`, `syncProblem`, `signIn`, `signOut`, `restoreSession` are removed):
  - `sessions: [AccountSession]` in `settings.accountIDs` order (only accounts whose credential loaded); `session(for: AccountID) -> AccountSession?`.
  - `isSignedIn: Bool` (`!sessions.isEmpty`), `isSyncing: Bool` (any), `needsReauth: [AccountSession]`.
  - `viewers: ViewerLogins` (logins of all sessions).
  - `lastSyncAt: Date?`: oldest `lastSyncAt` of sessions with `auth == .ok`; if none is `.ok`, oldest of all; nil if any considered session has none.
  - `ownership: [RepoID: AccountID]` (last computed); `owner(of: RepoID) -> AccountSession?`.
  - `repos: [RepoID: RepoState]`: states of every repo, taken from its owning session (fall back to the session that has the state when ownership is not yet computed).
  - `records(in: RepoID?) -> [ItemRecord]`, `counts(in: RepoID?) -> AttentionCounts` over `repos`.
  - `restoreSessions() async`: builds a session per id in `accountIDs` whose credential loads (an id whose account file is missing signs in with the stored credential, as today; failures are skipped and stay in `accountIDs`), writes the snapshot, then `refresh()`.
  - `addAccount(token: String, kind: CredentialKind) async throws`: validates via `viewer()`, loads or creates the account file, saves credential; appends the id to `accountIDs` unless present (then replaces that session's credential/API in place); `refresh()`.
  - `startDeviceFlow()`, `completeDeviceFlow(_:)` → `addAccount(..., kind: .oauth)`.
  - `removeAccount(_ id: AccountID) throws`: deletes its credential, ends and drops its session, removes the id from `accountIDs`; the account file stays; then `requestRefresh()` so another account can take over.
  - `resetAllData() throws`: as today, for all sessions.
  - `refresh() async`: one pass: (1) `resolve()` for each session sequentially in account order; (2) `ownership = RepoOwnership.assign(sessions.map { ($0.accountID, $0.watchedRepos()) })` (sessions that failed to resolve still contribute their persisted list); (3) for every session whose `resolve()` returned true, concurrently `syncItems(owned: watched repos it owns, keep: ids of its stored states whose `repo.owner` is in `session.unknownOwners` and that no other account owns, viewers: viewers)`; (4) call `onSyncReport(session.account, report)` per completed session, then write the snapshot once.
  - Mark routing: `markSeen/markUnseen(_ key:)` → `owner(of: key.repo)`; dropped when no owner. `markRepoSeen(_:)` likewise. `markAllSeen()` → every session.
  - Watch: `setOwnerMode(_:for owner: String, in: AccountID)`, `setNotifications(_:for: RepoID, in: AccountID)`, `setShowArchived(_:in: AccountID)`.
  - `@ObservationIgnored var onSyncReport: ((AccountData, SyncReport) -> Void)?`.
  - Snapshot: the merged snapshot is Task 6. In this task keep calling the existing `WidgetSnapshot.make(account:...)` with the first session's account (signed out when there is none), so behaviour stays defined.

- [ ] **Step 1: Write the failing tests** in `MultiAccountTests.swift`. Harness: like `RadarixControllerTests.Harness`, but `makeAPI` returns a separate `StubGitHubAPI` per token (`apis: [String: StubGitHubAPI]`, tokens `"t-me"` → viewer `(1, "me")`, `"t-work"` → viewer `(2, "work")`). Tests:
  - `upgradeFromV2KeepsSession`: write `plan2-settings.json` content (account 42) + account file + credential → `restoreSessions()` → `sessions.map(\.accountID) == [42]`, records of the stored account visible, no `viewer()` call needed.
  - `addSecondAccountAppends`: add `t-me` then `t-work` → `settings.accountIDs == [1, 2]`, both sessions present, `viewers.contains("work")`.
  - `addingSameAccountTwiceKeepsOneEntry`: add `t-me` twice (second with `.personalToken`) → `accountIDs == [1]`, `session(for: 1)?.credentialKind == .personalToken`.
  - `sharedRepoListedOnce`: both accounts watch owner `"org"` in `.all`, both list repo 7 with one open issue that becomes new → `records(in: nil).count == 1`, `counts(in: nil).new == 1`, `ownership[7] == 1`, account 2's `AccountData.repos[7] == nil`, `onSyncReport` delivered the new item only in account 1's report.
  - `reauthAccountDoesNotStopOthers`: account 2's API answers `owners()` with `.unauthorized`; account 1 gets a new issue → account 1's record is new, `session(for: 2)?.auth == .needsReauth`, account 2's stored records still in `records(in: nil)`.
  - `unhealthyOwnerKeepsSharedRepo`: account 1 offline (`owners()` throws `.network` with no known owners, persisted `available` lists repo 7) → `ownership[7] == 1`, account 2 does not sync repo 7.
  - `takeoverBaselinesWithoutNewItems`: shared repo 7 owned by account 1 with 2 open issues; `removeAccount(1)`; `refresh()` → `ownership[7] == 2`, both issues listed with attention `.seen`, report for account 2 has no `newItems`.
  - `reAddedAccountGoesLastAndDropsForeignState`: remove account 1, refresh (2 takes repo 7), add `t-me` again → `accountIDs == [2, 1]`, `ownership[7] == 2`, after refresh account 1's file has no `RepoState` for 7.
  - `ownActivityFromOtherAccountStaysSeen`: repo 7 owned by account 1, a seen issue moves; timeline shows a comment by `"work"` only → attention stays `.seen`.
  - `markRoutesToOwningSession`: shared repo 7 owned by 1, mark an item seen → account 1's record seen; account 2 has none.
  - `markDuringSyncOnRemovedOwnerIsDropped`: start a refresh, `removeAccount(1)` while account 1's items request is suspended, mark an item of repo 7 → no crash, nothing applied to account 2.
  - `lastSyncAtIsOldestHealthy`: account 1 synced at T1, account 2 at T2 > T1 → `lastSyncAt == T1`; account 1 needs reauth → `lastSyncAt == T2`.
  - `removeKeepsAccountFile`: after `removeAccount(2)` the file `accounts/2.json` still exists and the credential for 2 is gone.
  - Port the single-account controller tests to the new API (`restoreSessions`, `addAccount`, `removeAccount`, `session(for:)`) keeping every assertion; none is dropped.
- [ ] **Step 2: Run** `swift test --filter MultiAccountTests` → FAIL.
- [ ] **Step 3: Implement** the workspace as specified. Scheduler, `requestRefresh`/`followUpRefresh` and `snapshotReloadAge` dedupe stay in the controller and now cover the whole pass.
- [ ] **Step 4: Run** `swift test` → all pass.
- [ ] **Step 5: Commit** `feat(kit): watch several GitHub accounts in one workspace`

(The app target does not compile after this task until Task 7; that is expected. Do not touch `App/` here.)

---

### Task 6: Merged widget snapshot

**Files:**
- Modify: `Packages/RadarixKit/Sources/RadarixKit/Snapshot/WidgetSnapshot.swift`, `Controller/RadarixController.swift`
- Test: `WidgetSnapshotTests.swift`, `MultiAccountTests.swift`

**Interfaces:**
- Produces:
  - `WidgetSnapshot.logins: [String]` (replaces `login`), `WidgetSnapshot.reauthLogins: [String]`. Tolerant decode: a file with `login: "x"` and no `logins` decodes to `logins == ["x"]`; missing `reauthLogins` → `[]`. Encoding writes only `logins` and `reauthLogins`. Update `snapshotJSONHasOnlyKnownKeys` to the new key set.
  - `init(status:logins:reauthLogins:syncedAt:repos:)`.
  - `static func make(repos: [RepoState], logins: [String], reauthLogins: [String], settings: AppSettings, syncedAt: Date?) -> WidgetSnapshot`; status: `.signedOut` if `logins` is empty, `.needsReauth` if every login is in `reauthLogins`, else `.ok`. Repo entries as today, one per given state.
  - The controller writes `make(repos: Array(repos.values), logins: sessions.map(\.login), reauthLogins: needsReauth.map(\.login), settings:, syncedAt: lastSyncAt ?? carriedSyncedAt)`; `carriedSyncedAt` is taken from the previous snapshot when its `logins` equal the current ones case-insensitively as a set.

- [ ] **Step 1: Write the failing tests**: `legacyLoginDecodesToLogins`; `statusNeedsReauthOnlyWhenAllNeedIt` (logins `["a","b"]`, reauth `["a"]` → `.ok`; reauth `["a","b"]` → `.needsReauth`; logins `[]` → `.signedOut`); `ownerScopeSpansAccounts` (repos of owner `"org"` from two accounts' states → `summary(for: .owner("org")).repos.count == 2`); in `MultiAccountTests`: `snapshotCoversAllAccounts` (two accounts each with one new item → saved snapshot `summary(for: .all).newCount == 2`, `logins == ["me", "work"]`).
- [ ] **Step 2: Run** → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** `swift test` → all pass.
- [ ] **Step 5: Commit** `feat(kit): one widget snapshot across all accounts`

---

### Task 7: App: main window, menu bar, notifications

**Files:**
- Modify: `App/AppModel.swift`, `App/RadarixApp.swift`, `App/Main/MainWindow.swift`, `App/Main/MainNavigation.swift`, `App/Main/SidebarLayout.swift`, `App/Main/PreviewSamples.swift`, `App/MenuBar/MenuBarLabel.swift`, `App/MenuBar/MenuBarPopover.swift`, `App/Notifications/NotificationService.swift`, `App/Resources/Localizable.xcstrings`
- Test: app build; manual check in Step 4

**Interfaces:**
- Consumes: Task 5/6 controller API.
- Decisions:
  - `AppModel.start()` calls `restoreSessions()`; every `auth == .signedOut` check becomes `!controller.isSignedIn`.
  - `didSync(account:report:)` plans with `NotificationPlanner.plan(report, account: account, settings:)` (unchanged planner) and posts with `notifications.post(planned, accountLogin: controller.sessions.count > 1 ? account.login : nil)`; a non-nil `accountLogin` is prepended to the notification subtitle as `"<login> · <subtitle>"`.
  - `notifications.repo` looks up `controller.repos[id]?.repo`.
  - `grantAccessURL(for session: AccountSession) -> URL` (per account credential kind).
  - `MainNavigation.init?(_ link: DeepLink, repos: [RepoID: RepoState], layout:)` (was `in account:`), same rules.
  - Sidebar: `SidebarLayout` gets `accountSections: [AccountSection]` where `struct AccountSection { let login: String; let repos: [RepoSection] }`, built from `controller.sessions` in order, each holding the repos it owns (`controller.ownership`), ordered by that session's `owners` then name. With one session no account header is drawn (looks like today). An org shared by two accounts appears under each with only that account's repos.
  - Viewer for filters: `controller.viewers`.
  - Banners and popover notices per session: needs-reauth shows `"%@: sign in again"` when there is more than one session, otherwise today's text; offline and rate-limit banners use the session's `syncProblem`/`lastReport`, one line per affected session, login-prefixed only with more than one session. Repo failure banner reads failures from every session's `lastReport`.
  - `MenuBarLabel` shows its needs-reauth state when `!controller.needsReauth.isEmpty`.
  - New strings + German: `"%@: sign in again"` → `"%@: erneut anmelden"`.

- [ ] **Step 1: Make the app compile** against the new API with the decisions above.
- [ ] **Step 2: Build** (Global Constraints command) → `** BUILD SUCCEEDED **`, no new warnings.
- [ ] **Step 3: Run** `swift test` → all pass.
- [ ] **Step 4: Manual check** (report what you saw): launch the Debug build with an existing single account → main window, sidebar, popover look as before.
- [ ] **Step 5: Commit** `feat: show every account in the main window and menu bar`

---

### Task 8: App: Accounts and Repositories settings

**Files:**
- Modify: `App/Settings/AccountSettings.swift` (becomes the Accounts tab), `App/Settings/DeviceFlowSheet.swift`, `App/Settings/RepositorySettings.swift`, `App/Settings/SettingsView.swift`, `App/Resources/Localizable.xcstrings`
- Test: app build; manual check

**Interfaces:**
- Consumes: Task 5 controller API.
- Decisions:
  - Tab title `"Accounts"` (`"Konten"`).
  - Signed out (no sessions): today's sign-in section (Sign in with GitHub, token under Advanced) plus "Reset all data…", unchanged.
  - Signed in: one `Section` per session: login, sign-in kind, status (OK / sign in again / offline / rate limited, reuse existing strings), rate limit and last sync (existing strings), buttons "Sign in again" (opens the add sheet) when it needs reauth, and `"Remove"` (`"Entfernen"`, no confirmation: data stays). Below the sessions: `"Add account…"` (`"Konto hinzufügen…"`) opening a sheet with today's sign-in section, the device flow and the token field, plus the line `"Make sure the right account is signed in on github.com."` (`"Achte darauf, dass auf github.com das richtige Konto angemeldet ist."`). The sheet closes when `addAccount`/`completeDeviceFlow` returns. Then "Reset all data…".
  - `DeviceFlowSheet` completes on the return of `completeDeviceFlow` instead of watching `auth`.
  - Repositories tab: one `Section` header per session (login) when there is more than one; inside, today's owner list for that session (`session.owners`, `session.account.available`, `session.lastReport?.ownerIssues`). A repo whose `controller.ownership[repo.id]` is another account shows its toggle on and disabled with `"Watched via %@"` (`"Beobachtet über %@"`) and its notification toggle hidden. The restricted-org link uses `grantAccessURL(for: session)`.

- [ ] **Step 1: Implement** the views.
- [ ] **Step 2: Build** → succeeds, no new warnings.
- [ ] **Step 3: Manual check**: Accounts tab with one account; open and cancel "Add account…"; Repositories tab unchanged for one account.
- [ ] **Step 4: Commit** `feat: manage several accounts in settings`

---

### Task 9: Widget, docs and follow-ups

**Files:**
- Modify: `Widget/RadarixWidget.swift`, `Widget/WidgetViews.swift`, `Widget/ScopeIntent.swift` (only if it reads `login`), `Widget/Resources/Localizable.xcstrings`, `docs/specs/2026-11-24-radarix-design.md` (non-goal line), `docs/plans/2026-11-24-radarix-menubar-widget-followups.md`
- Test: app build (widget target is embedded)

**Interfaces:**
- Consumes: `WidgetSnapshot.logins`, `reauthLogins` (Task 6).
- Decisions:
  - With `status == .ok` and non-empty `reauthLogins`, the widget adds one caption line in the place of the stale note: one login → `"%@: sign in again"` (`"%@: erneut anmelden"`); more → `"%lld accounts need sign-in"` (`"%lld Konten müssen neu angemeldet werden"`). If the data is also stale, the reauth line wins.
  - Previews use `logins: ["octo"]`.
  - Spec: replace the non-goal "More than one GitHub account at a time…" with a pointer to `2026-11-24-radarix-multi-account-design.md`.
  - Follow-ups file: remove the resolved "Open decision" (storage fallback shipped in 5244e8c; team signing still needed for the widget, keep that sentence under Widget) and add any items this plan's reviews defer.

- [ ] **Step 1: Implement.**
- [ ] **Step 2: Build** → succeeds; `swift test` → all pass.
- [ ] **Step 3: Commit** `feat(widget): show accounts that need sign-in` and `docs: record the multi-account design in the specs and follow-ups` (two commits).
