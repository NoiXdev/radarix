# Radarix 1.1 refinements Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Five refinements on top of 1.0.0:
- persisted filters;
- widget filters;
- per-kind sidebar badges;
- "All" grouped by repository;
- a rendered description window.

**Architecture:**
- Logic goes into `RadarixKit` with tests: settings fields, the shared filter predicate, per-kind counts, the snapshot flags and the rendered-body fetch.
- The app and the widget only wire it up.
- The description window loads GitHub's `body_html` on demand and shows it in a JavaScript-free web view.

**Tech Stack:** Swift 6 (strict concurrency), SwiftUI, WidgetKit/AppIntents, WebKit, Swift Testing, XcodeGen.

**Spec:** `docs/specs/2026-11-24-radarix-refinements-design.md`

## Global Constraints

- **Branch:** `feat/radarix-refinements` from `main`, worked in place. Commit per task with Conventional Commits and the footer `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. Never push.
- **Platform and toolchain:** macOS 15. The code must build on Xcode 26.6 / Swift 6.3.3 (CI) and on Xcode 27. Do not pass a method reference as a SwiftUI `Binding` setter, because Swift 6.3 crashes on it. Use a closure.
- **Warnings:** no new warnings.
- **Kit tests:** `cd Packages/RadarixKit && swift test`.
- **App build:** `/opt/homebrew/bin/xcodegen generate -q && xcodebuild -project Radarix.xcodeproj -scheme Radarix -configuration Debug -derivedDataPath DerivedData build`.
- **Strings:** every new user-visible string goes into `App/Resources/Localizable.xcstrings` or `Widget/Resources/Localizable.xcstrings`, in English and German.
- **Persistence:** new persisted fields decode with `decodeIfPresent` and a default. A 1.0.0 `settings.json` and a 1.0.0 `widget-snapshot.json` must still load.
- **Widget snapshot privacy:** no account ids, credentials or logins beyond today's `logins`/`reauthLogins` fields.
- **Description window:**
  - JavaScript off;
  - no in-view navigation after the first load;
  - `http(s)` links open in the default browser;
  - a non-persistent website data store;
  - the token goes only to `api.github.com`, through the existing `GitHubClient`.
- **Double click** on an item still opens it on GitHub.

## Review Focus

1. **A 1.0.0 `settings.json`** (no `filter`, `showsBots` or `groupAllByRepo`) loads with defaults and keeps the accounts. Pinned in Task 1.
2. **A `filter` object missing a key** (a future chip) keeps the other chips and does not reset the settings. Pinned in Task 1.
3. **A repo with more new/updated items than the snapshot cap** and a filter active: the widget counts never read lower than the real number without saying so. Pinned in Task 4 (`isTruncated`).
4. **An item from a repo whose owning session is gone**, or offline: the description window keeps the excerpt and shows the error. It does not crash or spin forever. Pinned in Task 6 (controller throws `.noOwner`) and Task 7 (error state).
5. **Body HTML with `<script>`, `javascript:` links or a link to another site:** nothing runs, and nothing navigates inside the view. Pinned in Task 7, by a manual check with a fixture HTML.

---

### Task 1: Persisted filters and settings fields

**Files:**
- Modify: `Packages/RadarixKit/Sources/RadarixKit/Model/Settings.swift`
- Modify: `Packages/RadarixKit/Sources/RadarixKit/Filtering/ItemFilter.swift`
- Modify: `App/Main/MainWindow.swift` (remove `@SceneStorage` `main.filter` and `main.showsBots`; read and write the settings)
- Test: `Packages/RadarixKit/Tests/RadarixKitTests/SchemaEvolutionTests.swift`, `ItemFilterTests.swift`

**Interfaces:**
- Produces:
  - `AppSettings.filter: FilterSet` (default `FilterSet()`);
  - `AppSettings.showsBots: Bool` (default `false`);
  - `AppSettings.groupAllByRepo: Bool` (default `false`). Task 3 uses it.
  - `currentSchemaVersion` becomes `4`.
- Produces: `FilterSet.init(from:)`, which is tolerant: every flag uses `decodeIfPresent` with the property's default.
- Produces: `FilterSet.matches(attention: Attention, kind: ItemKind, isUnassigned: Bool, isAssignedToViewer: Bool, isReviewRequestedFromViewer: Bool) -> Bool`. It is the one predicate, and `ItemFilter.matches` calls it. Task 4 and Task 5 call it for the widget.

- [ ] **Step 1: Write the failing tests.**
  - `settingsFromOneZeroLoadWithFilterDefaults`: decode a 1.0.0-shaped JSON (schema 3, no new keys, `accountIDs: [42]`). Expect `filter == FilterSet()`, `showsBots == false`, `groupAllByRepo == false`, and `accountIDs == [42]`.
  - `filterRoundTripsThroughSettings`: set `filter.assignedToMe = true` and `filter.new = false`, then encode and decode. The result is equal.
  - `filterMissingAKeyKeepsTheOthers`: decode `{"new":false,"issues":true}`. Expect `new == false`, `issues == true`, `updated == true`, and the rest at their defaults.
  - `sharedPredicateMatchesItemFilter`: for a table of records, `ItemFilter.visible` gives the same membership as `FilterSet.matches` called with the record's fields.
- [ ] **Step 2: Run the tests.** Command: `cd Packages/RadarixKit && swift test --filter "SchemaEvolution|ItemFilter"`. Expected: the new tests FAIL.
- [ ] **Step 3: Implement the kit changes.** Add the fields to `CodingKeys`, `init(from:)` and `encode(to:)`. Write the `FilterSet` decoder, and pull the predicate out of `ItemFilter.matches` into `FilterSet.matches`.
- [ ] **Step 4: Make `MainWindow` use the settings.**
  - Its `filter` binding reads `controller.settings.filter` and writes through `set: { value in controller.updateSettings { $0.filter = value } }`.
  - Do the same for `showsBots`.
  - The `.onChange(of: storedFilter)` and `.onChange(of: showsBots)` handlers become `.onChange(of: controller.settings.filter)` and `.onChange(of: controller.settings.showsBots)`.
- [ ] **Step 5: Run the kit tests and the app build.** Expected: all pass, 0 warnings.
- [ ] **Step 6: Manual check.** Set a filter, quit Radarix, then relaunch. The same chips are on.
- [ ] **Step 7: Commit.** Message: `feat: keep the list filters across launches`.

---

### Task 2: Per-kind counts and sidebar badges

**Files:**
- Modify: `Packages/RadarixKit/Sources/RadarixKit/Filtering/ItemFilter.swift`
- Modify: `Packages/RadarixKit/Sources/RadarixKit/Controller/RadarixController.swift` (next to `counts(in:)`)
- Modify:
  - `App/Main/ItemRow.swift` (new `KindBadges` view next to `AttentionBadges`, plus two kind colors);
  - `App/Main/MainWindow.swift` (`RepoSection` gets `kindCounts`);
  - `App/Main/SidebarLayout.swift` ("All" and repo rows);
  - `App/Main/GroupedListLayout.swift` (section headers).
- Test: `ItemFilterTests.swift`

**Interfaces:**
- Produces: `public struct KindCounts: Sendable, Equatable`, with `pullRequests: AttentionCounts`, `issues: AttentionCounts`, `var total: AttentionCounts` (the sum) and a public memberwise init with defaults.
- Produces: `ItemFilter.kindCounts(_ records: [ItemRecord], bots: BotDisplayMode) -> KindCounts`. The inclusion rules are exactly those of `ItemFilter.counts`.
- Produces: `RadarixController.kindCounts(in repo: RepoID?) -> KindCounts`.
- Unchanged: `counts(in:)` and `AttentionCounts`. The menu bar and the widget keep using them.

- [ ] **Step 1: Write the failing tests.**
  - `kindCountsSplitByKind`: 2 new PRs, 1 updated PR, 1 new issue and 1 seen issue. Expect `pullRequests == AttentionCounts(new: 2, updated: 1)`, `issues == AttentionCounts(new: 1, updated: 0)`, and `total == ItemFilter.counts(...)`.
  - `kindCountsHiddenBotsLeftOut`: in `.hidden` mode, a new bot PR is not counted.
- [ ] **Step 2: Run the tests.** Expected: FAIL.
- [ ] **Step 3: Implement the counts.** Add `KindCounts`, `ItemFilter.kindCounts` and `RadarixController.kindCounts(in:)`.
- [ ] **Step 4: Build `KindBadges(counts: KindCounts)`.**
  - It shows up to two capsules: PR glyph `arrow.triangle.pull` and issue glyph `exclamationmark.circle`, each with the kind's new+updated count, tinted in the kind color.
  - A kind with a total of 0 is not shown.
  - Each capsule carries a dot: `attentionNew` when that kind has `new > 0`, otherwise `attentionUpdated`.
  - Accessibility label: "%lld pull requests, %lld new, %lld updated", and the same for issues.
  - The kind colors are your call. They must differ clearly from the attention blue/amber and from the status green/purple/red, in light and dark mode. Define them next to `attentionNew`.
- [ ] **Step 5: Replace `AttentionBadges` with `KindBadges`** in the sidebar ("All" uses `controller.kindCounts(in: nil)`, repo rows use the `RepoSection`'s) and in the grouped section headers. `AttentionBadges` stays where it is used elsewhere (the popover).
- [ ] **Step 6: Build, and check by eye** in light and dark mode, with one account and with two.
- [ ] **Step 7: Commit.** Message: `feat: split the sidebar counts into pull requests and issues`.

---

### Task 3: Group "All" by repository

**Files:**
- Modify: `App/Main/SidebarLayout.swift`, `App/Main/GroupedListLayout.swift`, `App/Main/MainWindow.swift`

**Interfaces:**
- Consumes: `AppSettings.groupAllByRepo` (Task 1), `KindBadges` (Task 2).
- Produces:
  - a view `RepoSectionList(sections: [RepoSection], selection: Binding<ItemKey?>, scrollTarget: Binding<ScrollTarget?>, showsBotBadges: Bool, actions: ItemActions)`, extracted from `GroupedListLayout.list` with its scroll handling;
  - `GroupedListLayout` renders through it.

- [ ] **Step 1: Extract `RepoSectionList`** from `GroupedListLayout`. Behaviour must not change: hidden empty sections, the headers, the context menu, the empty overlay, and the `.item`/`.repo` scroll targets. Build it, and check the grouped layout by eye.
- [ ] **Step 2: Add the toolbar toggle.**
  - The toggle reads "Group by repository", with the system image `rectangle.grid.1x2`.
  - It shows in `SidebarLayout` only while the sidebar selection is "All".
  - It binds to `controller.settings.groupAllByRepo` through a closure setter.
- [ ] **Step 3: With the toggle on and "All" selected**, the middle column shows `RepoSectionList(sections: repoSections, …)` in sidebar order instead of the flat list.
  - The item row inside a section uses `showsRepo: false`, as in the grouped layout.
  - Deep-link scrolling to an item still works.
- [ ] **Step 4: Build.** Check by eye: toggle on and off, the setting kept across a relaunch, and the toggle hidden on a single repo.
- [ ] **Step 5: Commit.** Message: `feat: group the All list by repository`.

---

### Task 4: Widget snapshot for filtering

**Files:**
- Modify: `Packages/RadarixKit/Sources/RadarixKit/Snapshot/WidgetSnapshot.swift`
- Modify: `Packages/RadarixKit/Sources/RadarixKit/Controller/RadarixController.swift:505` (pass the viewers into `make`)
- Test: `WidgetSnapshotTests.swift`

**Interfaces:**
- Consumes: `FilterSet.matches(...)` (Task 1).
- Produces:
  - `ItemEntry` gains `isUnassigned: Bool`, `isAssignedToViewer: Bool` and `isReviewRequestedFromViewer: Bool`. They decode with `decodeIfPresent ?? false`, so a 1.0.0 file loads.
  - `make(..., viewers: ViewerLogins, ...)` sets them.
- Produces: `WidgetSnapshot.itemsPerRepo` changes from `6` to `100`. That is the cap: the newest 100 new/updated items per repository.
- Produces: `RepoEntry.isTruncated: Bool` (true when `newCount + updatedCount > items.count`, computed, not stored).
- Produces: `summary(for scope: WidgetScope, filter: FilterSet) -> Summary`.
  - When `filter == FilterSet()` (no filter), the counts are today's stored `newCount`/`updatedCount`.
  - Otherwise the counts are taken from the filtered items.
  - `Summary` gains `isLowerBound: Bool`: true when a filter is active and a chosen repo `isTruncated`.
  - With both `filter.new` and `filter.updated` false, the snapshot treats them as both true.
  - The existing `summary(for:)` becomes `summary(for: scope, filter: FilterSet())`.

- [ ] **Step 1: Write the failing tests.**
  - `snapshotFlagsAssignmentForViewers`: an item assigned to "Me" (with viewers ["me"]) gets `isAssignedToViewer == true`, and one with no assignees gets `isUnassigned == true`.
  - `oneZeroSnapshotLoads`: decode a 1.0.0 snapshot JSON. The flags are false.
  - `filteredSummaryCountsOnlyMatches`: 3 new PRs and 2 new issues, with `filter.pullRequests = true`. Expect `newCount == 3`, the items are PRs only, and `isLowerBound == false`.
  - `bothAttentionOffMeansBoth`: `filter.new = false, filter.updated = false` gives the same result as the default.
  - `truncatedRepoMakesFilteredCountsALowerBound`: 101 new items with a filter active gives `isLowerBound == true`, and with no filter the stored counts (101).
- [ ] **Step 2: Run the tests.** Expected: FAIL.
- [ ] **Step 3: Implement the snapshot changes**, and pass `ViewerLogins` from the controller.
- [ ] **Step 4: Run the kit tests.** Expected: all pass.
- [ ] **Step 5: Commit.** Message: `feat: give the widget snapshot what filters need`.

---

### Task 5: Widget filter settings

**Files:**
- Modify: `Widget/ScopeIntent.swift`, `Widget/RadarixWidget.swift`, `Widget/WidgetViews.swift`, `Widget/Resources/Localizable.xcstrings`

**Interfaces:**
- Consumes: `summary(for:filter:)` and `Summary.isLowerBound` (Task 4).
- Produces: `ScopeIntent` gets the parameters below, plus `var filter: FilterSet { … }` built from them.

  | Parameter | Title | Default |
  |---|---|---|
  | `new` | "New" | true |
  | `updated` | "Updated" | true |
  | `unassigned` | "Unassigned" | false |
  | `assignedToMe` | "Assigned to me" | false |
  | `reviewRequested` | "Review requested" | false |
  | `pullRequests` | "Pull requests" | false |
  | `issues` | "Issues" | false |

  - `parameterSummary` groups them under "Show", then attention, assignment and kind.
  - A widget configured with 1.0.0 (without these parameters) gets the defaults.

- [ ] **Step 1: Add the parameters** and `filter`. `OverviewEntry.summary` calls `summary(for: scope, filter: configuration.filter)`.
- [ ] **Step 2: Mark an active filter in the views.**
  - When `configuration.filter != FilterSet()`, the existing caption line shows a short description of it. Join the active chips with " · ", for example "Assigned to me · Pull requests". The wording is yours, in both languages.
  - When `isLowerBound`, the counts show a trailing "+".
  - An empty result uses the existing nothing-new state.
- [ ] **Step 3: Build.** Then add widgets with different filters in the widget gallery and check each family by eye.
- [ ] **Step 4: Commit.** Message: `feat: let each widget filter what it shows`.

---

### Task 6: Rendered description fetch (kit)

**Files:**
- Modify: `Packages/RadarixKit/Sources/RadarixKit/GitHub/GitHubClient.swift` (`get` gets an `accept: String = "application/vnd.github+json"` parameter, which reaches `perform`)
- Modify: `Packages/RadarixKit/Sources/RadarixKit/GitHub/GitHubAPI.swift` (protocol and implementation)
- Modify: `Packages/RadarixKit/Sources/RadarixKit/Controller/RadarixController.swift`
- Modify: `Packages/RadarixKit/Tests/RadarixKitTests/Support/StubGitHubAPI.swift`
- Test: `GitHubAPITests.swift`, `RadarixControllerTests.swift`

**Interfaces:**
- Produces: `GitHubAPI.renderedBody(number: Int, in repo: RepoRef) async throws -> String?`.
  - It sends `GET /repos/{owner}/{name}/issues/{number}` with `Accept: application/vnd.github.html+json`.
  - It decodes `{"body_html": String?}`. Nil or empty gives nil.
  - It is not conditional, and it stores no ETag.
- Produces: `RadarixController.renderedDescription(of key: ItemKey) async throws -> String?`.
  - It uses the `owner(of: key.repo)` session's API and the `RepoRef` from `repos[key.repo]`.
  - If there is no owner or no repo state, it throws `DescriptionError.noOwner`, a new `public enum DescriptionError: Error { case noOwner }`.
  - It does not touch the sync state.
- `AccountSession` exposes `func renderedBody(number: Int, in repo: RepoRef) async throws -> String?`, which forwards to its private `api`.

- [ ] **Step 1: Write the failing tests.**
  - `renderedBodyRequestsHTML`: with a stub transport, the request path is `/repos/o/r/issues/7`, the `Accept` header is `application/vnd.github.html+json`, and `Authorization` is `Bearer <token>`. A body `{"body_html":"<p>Hi</p>"}` returns `"<p>Hi</p>"`.
  - `renderedBodyNullIsNil`: `{"body_html":null}` returns nil.
  - `renderedDescriptionUsesOwningAccount`: with two accounts, the repo is owned by the second, and that account's stub is called.
  - `renderedDescriptionWithoutOwnerThrows`: an unknown repo throws `.noOwner`.
- [ ] **Step 2: Run the tests.** Expected: FAIL.
- [ ] **Step 3: Implement**, and script `renderedBody` in `StubGitHubAPI`.
- [ ] **Step 4: Run the kit tests.** Expected: all pass.
- [ ] **Step 5: Commit.** Message: `feat: fetch an item's rendered description`.

---

### Task 7: Description window

**Files:**
- Create: `App/Description/DescriptionWindow.swift`, `App/Description/DescriptionWebView.swift`
- Modify:
  - `App/RadarixApp.swift`: add `WindowGroup(id: "description", for: ItemKey.self)`. `ItemKey` must be `Codable` and `Hashable`; it already is, so check.
  - `App/Main/ItemDetail.swift`: the inline excerpt is replaced by a "Show description" button.
  - `App/Main/ItemRow.swift`: the context menu gets "Show Description".
  - `App/Main/SidebarLayout.swift` and `RepoSectionList`: the Space key on the selected item.
  - `App/Main/MainWindow.swift`: `ItemActions` gets `showDescription: @MainActor (ItemKey) -> Void`, which calls `openWindow(id: "description", value: key)`.
- Modify: `project.yml`, only if the WebKit framework needs linking explicitly.

**Interfaces:**
- Consumes: `RadarixController.renderedDescription(of:)` and `DescriptionError` (Task 6).
- `DescriptionWebView(html: String, baseURL: URL)` is an `NSViewRepresentable` around `WKWebView`:
  - `WKWebViewConfiguration.websiteDataStore = .nonPersistent()`;
  - `defaultWebpagePreferences.allowsContentJavaScript = false`;
  - the navigation delegate allows only the first `loadHTMLString` navigation. A link click with an `http`/`https` URL calls `NSWorkspace.shared.open` and is cancelled. Everything else is cancelled.

- [ ] **Step 1: Build `DescriptionWindow(key: ItemKey)`.**
  - **Header:** `KindMarker`, then `owner/name #number`, the title, and an "Open on GitHub" button.
  - **Body:** `DescriptionWebView`.
  - **Window title:** `owner/name #number`, with a default size of about 720×640.
  - **While loading:** the stored `bodyExcerpt` as plain text, with a small progress indicator.
  - **On error:** the excerpt, one line "Couldn't load the description." and a "Try again" button.
  - **Nil body:** "No description."
  - **On appear:** the item is marked seen (`controller.markSeen`).
- [ ] **Step 2: Wrap `body_html`** in a full HTML page with an inline stylesheet:
  - `font: -apple-system-body`;
  - `color-scheme: light dark`;
  - `pre`/`code` with a monospaced font and a subtle background;
  - tables with borders;
  - `img { max-width: 100% }`;
  - task-list checkboxes without bullets.

  The base URL is `https://github.com/<owner>/<name>/`.
- [ ] **Step 3: Wire the three ways to open the window.**
  - The inspector button "Show description".
  - The context menu "Show Description".
  - Space on the list: `.onKeyPress(.space)` on the item lists opens the selected item's window.
  - In the window, Escape closes it (`.keyboardShortcut(.cancelAction)` on a hidden close button, or `onExitCommand`).
  - Opening the same key again brings its existing window to the front. That is `WindowGroup(for:)` behaviour, so check it.
- [ ] **Step 4: Manual checks.**
  - A real issue with a table, a task list, code and an image renders as on github.com.
  - A link opens in the browser.
  - Offline: excerpt plus error, and "Try again" works when back online.
  - **Review Focus 5:** temporarily feed `<script>document.body.innerHTML='x'</script><a href="javascript:alert(1)">j</a><a href="https://example.com">e</a>`.
    - Nothing runs.
    - The `javascript:` link does nothing.
    - example.com opens in the browser, not in the view.
    - Remove the fixture afterwards.
- [ ] **Step 5: Build.** Expected: 0 warnings, on Xcode 27 locally. Keep the Swift 6.3 setter rule in mind.
- [ ] **Step 6: Commit.** Message: `feat: show an item's description in its own window`.

---

### Task 8: User docs

**Files:**
- Modify, in `~/_dev/noix-docs` on the branch `docs/radarix` (not merged yet; commit on top of it):
  - `src/content/docs/radarix/guide/main-window.md`: grouping "All" and the description window;
  - `guide/menu-bar.md` or wherever the sidebar badges are described;
  - `guide/widget.md`: the filters;
  - `reference/settings.md`: filters kept across launches, and the grouping toggle.

- [ ] **Step 1: Update the pages.** Take the facts from the code of Tasks 1–7, with UI strings as the app shows them in English. Use short sentences and no implementation stack on marketing-level pages.
- [ ] **Step 2: Run `npm run check && npm run build`.** Expected: 0 errors.
- [ ] **Step 3: Commit on `docs/radarix`.** Message: `docs(radarix): document filters, badges, grouping and the description window`. Do not push.
