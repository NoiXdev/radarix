# Radarix 1.2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:**
- assign or unassign yourself;
- an optional inline description;
- background start and menu-bar-only mode;
- one instance per user;
- docs and website published.

**Architecture:**
- The GitHub write and all new settings live in `RadarixKit` with tests.
- The app wires the buttons, the inline view (reusing 1.1's description content) and the lifecycle in `AppDelegate`/`AppModel`.

**Tech Stack:** Swift 6, SwiftUI, AppKit (activation policy, `NSRunningApplication`), WebKit, Swift Testing.

**Spec:** `docs/specs/2026-11-24-radarix-assign-inline-design.md`

## Global Constraints

- **Branch:** `feat/radarix-1-2` from `main`, in place.
  - Use Conventional Commits with the footer `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
  - Never push from a task.
- **Build:** macOS 15. It must build on Xcode 26.6 / Swift 6.3 (CI) and on Xcode 27.
  - Never pass a method reference as a SwiftUI `Binding` setter.
  - The build has no new warnings.
- **Kit tests:** `cd Packages/RadarixKit && swift test`.
- **App build:** `/opt/homebrew/bin/xcodegen generate -q && xcodebuild -project Radarix.xcodeproj -scheme Radarix -configuration Debug -derivedDataPath DerivedData build`.
- **Strings:** new strings go in the App catalog, in EN and DE.
- **Settings decoding:** new settings use `decodeIfPresent` with defaults, so a 1.1 `settings.json` still loads.
- **GitHub writes:**
  - only `POST`/`DELETE …/issues/{n}/assignees`, with the viewer's own login;
  - only through `GitHubClient`, to its `baseURL`;
  - the owning account only.
- **Description security:** the inline view reuses `DescriptionWebView` and `DescriptionPage` unchanged. That keeps JavaScript off, the store non-persistent, the single allow, http(s) clicks to the browser, and the CSP.

## Review Focus

1. **GitHub answers 201 but leaves the login out** (no push access). Radarix must not show the item as assigned. Pinned in Task 2.
2. **A 1.1 `settings.json`** loads with the three new settings at their defaults. Pinned in Task 1.
3. **A second copy of Radarix is launched** while one runs: the first comes to the front, and the second exits without syncing or writing. Task 5, with a pure decision function tested in the kit, plus a manual check.
4. **Rapid selection changes with the inline description:** an older load never overwrites a newer item's view. Task 4.
5. **"Hide from the Dock" with a description window still open:** the Dock icon stays until the last Radarix window closes. Task 5, manual.

---

### Task 1: Settings fields

**Files:**
- Modify: `Packages/RadarixKit/Sources/RadarixKit/Model/Settings.swift`
- Test: `SchemaEvolutionTests.swift`

**Interfaces:**
- Produces:
  - `public enum DescriptionPlacement: String, Codable, Sendable { case window, sidebar }`;
  - `AppSettings.descriptionPlacement` (default `.window`);
  - `AppSettings.startInBackground` (default `false`);
  - `AppSettings.menuBarOnlyWhenClosed` (default `false`);
  - `currentSchemaVersion` = 5.

- [ ] **Step 1: Tests.**
  - `settingsFromOneOneLoadWithNewDefaults`: a schema 4 JSON without the keys loads with the defaults above and its accounts.
  - `newSettingsRoundTrip`: `.sidebar`, `true`, `true` encode and decode to the same value.
  - An unknown `descriptionPlacement` string falls back to `.window`, and the other settings are kept.
- [ ] **Step 2:** Run them. They should FAIL (RED). Implement, run again for GREEN, then run the full suite.
- [ ] **Step 3:** Commit: `feat: add the 1.2 settings`.

---

### Task 2: Assign API (kit)

**Files:**
- Modify:
  - `GitHub/GitHubClient.swift` (a general request with method and JSON body);
  - `GitHub/GitHubAPI.swift`;
  - `Controller/AccountSession.swift`;
  - `Controller/RadarixController.swift`;
  - `Tests/RadarixKitTests/Support/StubGitHubAPI.swift`.
- Test: `GitHubAPITests.swift`, `MultiAccountTests.swift`

**Interfaces:**
- Produces: `GitHubAPI.setAssigned(_ assigned: Bool, login: String, number: Int, in repo: RepoRef) async throws -> [String]`.
  - It sends `POST` (assign) or `DELETE` (unassign) to `/repos/{o}/{n}/issues/{number}/assignees`, with the body `{"assignees":[login]}` and `Content-Type: application/json`.
  - It decodes `assignees[].login` from the response.
- Produces: `public enum AssignError: Error, Equatable { case notPermitted, noOwner }`.
  - `notPermitted`: on assign, the returned list does not contain the login (case-insensitive); on unassign, it still contains it; or the HTTP status is 403 or 404.
  - Other errors stay `GitHubError`.
- Produces: `RadarixController.setAssigned(_ assigned: Bool, key: ItemKey) async throws`.
  - It goes through the owner session with its `login`.
  - On success it stores the returned list in the record's `item.assignees`, saves the account and writes the snapshot.
  - It leaves attention unchanged.
- Produces: `RadarixController.isAssignedToOwner(_ key: ItemKey) -> Bool?`, which is nil without an owner.
- Produces: `AccountSession.setAssignees(_ logins: [String], for key: ItemKey)`.

- [ ] **Step 1: Tests.**
  - `assignSendsPOSTWithBody`: checks the method, path, JSON body, Bearer token and `X-GitHub-Api-Version`.
  - `unassignSendsDELETE`.
  - `assignSilentlyDroppedIsNotPermitted`: a 201 with `{"assignees":[]}` throws `.notPermitted`.
  - `assign403IsNotPermitted`.
  - `controllerAssignUpdatesRecordWithoutChangingAttention`: two accounts, and the owner's login is used.
  - `controllerAssignWithoutOwnerThrows`.
- [ ] **Step 2:** RED, implement, GREEN, then the full suite.
- [ ] **Step 3:** Commit: `feat: assign and unassign the viewer on GitHub`.

---

### Task 3: Assign buttons

**Files:**
- Modify:
  - `App/Main/ItemDetail.swift`;
  - `App/Description/DescriptionWindow.swift`;
  - `App/Main/ItemRow.swift` (context menu);
  - `App/Main/MainWindow.swift` (`ItemActions` gets `setAssigned: @MainActor (ItemKey, Bool) async throws -> Void`);
  - `App/Settings/AccountSettings.swift` (token hint);
  - `App/Resources/Localizable.xcstrings`.

**Interfaces:**
- Consumes: Task 2.
- Strings (verbatim):
  - "Assign to me";
  - "Unassign me";
  - "This sign-in can't assign. A fine-grained token needs write access to issues and pull requests.";
  - the token hint becomes "Classic token: repo and read:org. Fine-grained token: read access to metadata, and read and write access to issues and pull requests, which assigning needs."

- [ ] **Step 1:** Build a small `AssignButton(key:)` view.
  - Its label comes from `controller.isAssignedToOwner(key)`, and it is hidden when that is nil.
  - While a request runs it is disabled and shows a `ProgressView`.
  - An error shows inline beneath it, using the strings above or `AppModel.message(for:)`.
  - Use it in the inspector and the description window.
- [ ] **Step 2:** In the context menu, add "Assign to me"/"Unassign me" for the single selected entry. It runs in a `Task`, and an error goes to the window's existing error surface. If there is none, log it and show nothing; record that choice in the report.
- [ ] **Step 3:** Build and commit: `feat: add assign and unassign buttons`.

---

### Task 4: Inline description

**Files:**
- Create: `App/Description/DescriptionContent.swift`, holding the load/excerpt/error/"Try again" body extracted from `DescriptionWindow`.
- Modify:
  - `App/Description/DescriptionWindow.swift` (uses it);
  - `App/Main/ItemDetail.swift`;
  - `App/Settings/GeneralSettings.swift` (picker "Show description": "In a window" / "In the sidebar").

**Interfaces:**
- Consumes: `AppSettings.descriptionPlacement` (Task 1).
- Produces: `DescriptionContent(key: ItemKey)`. It loads with `.task(id: key)`, so a newer key cancels an older load and an older result never lands (Review Focus 4).

- [ ] **Step 1:** Extract `DescriptionContent` with no change to the window's behaviour.
- [ ] **Step 2:** With `.sidebar`, `ItemDetail` shows `DescriptionContent` below the details, and the button reads "Open in window". With `.window`, it behaves as in 1.1.
- [ ] **Step 3:** Add the picker in General settings. The binding uses a closure setter.
- [ ] **Step 4:** Build and commit: `feat: show the description in the sidebar if chosen`.

---

### Task 5: Background start, menu bar only, one instance

**Files:**
- Create: `Packages/RadarixKit/Sources/RadarixKit/Lifecycle/InstancePolicy.swift`
- Modify:
  - `App/AppDelegate.swift`;
  - `App/AppModel.swift` (`claimLaunchWindow`);
  - `App/RadarixApp.swift` (window appear/disappear hooks);
  - `App/Settings/GeneralSettings.swift`.
- Test: `InstancePolicyTests.swift`

**Interfaces:**
- Produces: `InstancePolicy.shouldYield(selfPID: Int32, running: [(bundleID: String?, pid: Int32)], bundleID: String) -> Int32?`. It returns the pid of another instance with the same bundle id, or nil.
- Produces: `InstancePolicy.activationIsAccessory(menuBarOnly: Bool, openWindowCount: Int) -> Bool`.
- Settings strings (verbatim): "Start in the background", "Hide from the Dock when the window is closed".

- [ ] **Step 1: Kit tests.**
  - `yieldsToAnotherInstanceWithSameBundleID`
  - `ignoresItselfAndOtherApps`
  - `accessoryOnlyWhenMenuBarOnlyAndNoWindows`
- [ ] **Step 2: One instance.**
  - In `applicationWillFinishLaunching`, use `NSRunningApplication.runningApplications(withBundleIdentifier:)` and the policy.
  - If another instance is running, reopen it with `NSWorkspace.shared.openApplication(at: other.bundleURL, configuration:)`, then `NSApp.terminate(nil)`.
  - Do this before `model.start()` runs and before anything is written.
- [ ] **Step 3: Background start.** `claimLaunchWindow()` returns false when `settings.startInBackground` is on. Link and notification launches are unaffected.
- [ ] **Step 4: Menu bar only.**
  - Count the visible Radarix windows (main, description and Settings) on window become-visible and close, using `NSWindow` notifications in the app delegate.
  - Call `NSApp.setActivationPolicy(...)` from the policy.
  - When the setting turns off, switch back to `.regular` at once.
- [ ] **Step 5:** Add both toggles next to "Open at login", with closure setters.
- [ ] **Step 6:** Build and commit: `feat: start in the background, hide from the Dock, run once per user`.

---

### Task 6: User docs

**Files:**
- In `~/_dev/noix-docs`, on the branch `docs/radarix`:
  - `guide/main-window.md` (assign, inline description);
  - `reference/settings.md` (the three new settings);
  - `guide/accounts.md` or `sign-in.md` (write access for fine-grained tokens);
  - `reference/troubleshooting.md` (the "can't assign" message).

- [ ] **Step 1:** Write the facts from the code, using the strings as they are shown.
- [ ] **Step 2:** `npm run check && npm run build`, with 0 errors.
- [ ] **Step 3:** Commit on `docs/radarix`: `docs(radarix): document assigning, the inline description and the new settings`. Do not push.

---

### Controller steps after the final review (owner's go-ahead: "Docs und noix-Webseite nicht vergessen")

1. Merge `feat/radarix-1-2` into `main`. Push, then watch CI.
2. Tag `v1.2.0` (only on the owner's word at that point), then watch the release and the cask bump.
3. **noix-docs:**
   - Merge `docs/radarix` into `main`. Fast-forward if possible; otherwise a merge commit.
   - Run `npm run check && npm run build` on the merged tree, then push `main`.
4. **noix.dev:**
   - On `radarix`, set `docs: https://docs.noix.dev/radarix/` on both project pages.
   - Mention assigning in the page copy only if it fits the voice.
   - Run the site's check and build, then merge into `main` and push.
5. Deploying with Portainer is the owner's step. Tell them.
