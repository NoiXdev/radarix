# Radarix 1.3: repository info. Implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: use
> superpowers:subagent-driven-development (recommended) or
> superpowers:executing-plans to work through this plan task by task. Steps
> use checkbox (`- [ ]`) syntax for tracking.

**Goal:**

- a per-repository info window with current numbers and "new in the last N
  days";
- an overview table of all watched repositories.

**Architecture:**

- **The overview** reads counts that the repository listing already returns.
  They are stored per account as `RepoStats`, so the overview costs no
  request.
- **The info window** sends one GraphQL query when it opens. Stars and forks
  get extra pages only when a period holds more than 100 of them.

**Tech stack:** Swift 6 (strict concurrency), SwiftUI, Observation, Swift
Testing, XcodeGen. macOS 15.

**Spec:** `docs/specs/2026-11-25-radarix-repo-info-design.md`

## Global constraints

- **Toolchain:** Swift 6 strict concurrency, macOS 15, no new warnings.
- **Two compilers:** it must build on Xcode 26.6 / Swift 6.3 (CI) and on
  Xcode 27.
- **SwiftUI Bindings:** never pass a method reference as a `Binding` setter.
  Use closures, because of the Swift 6.3 IRGen crash.
- **Strings:** every new UI string goes into `App/Resources/Localizable.xcstrings`
  with **en, de, fr and pl**. State `translated`, and placeholders consistent
  across all four.
- **Persisted fields:** they use `decodeIfPresent` with defaults.
  - A 1.2 `settings.json` and an account file must still load.
  - The `AppSettings` schema goes 5 → 6; the `AccountData` schema goes 3 → 4.
- **Requests:** they go to `api.github.com` only, with the owning account's
  token.
  - A sync pass makes no extra request.
  - GraphQL responses never update `latestRateLimit`, which tracks REST
    `core`.
- **Kit tests:** `cd Packages/RadarixKit && swift test`. The app build:
  `/opt/homebrew/bin/xcodegen generate -q && xcodebuild -project Radarix.xcodeproj -scheme Radarix -configuration Debug -derivedDataPath DerivedData build`.
- **Commits:** Conventional Commits, ending with
  `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Review focus

1. **A repository with over 500 new stars in the period** shows "500+" and
   never a wrong exact number (Task 2: `starsCappedAtFivePages`).
2. **A GraphQL `errors` answer with HTTP 200** (repository gone, no access)
   shows "can't be read" and does not crash on null `data` (Task 2:
   `graphQLNotFoundMaps`).
3. **The window is opened while the main sync runs.** The REST rate limit
   shown in the app must not jump to GraphQL's numbers (Task 2:
   `graphQLLeavesRateLimit`).
4. **A 304 listing after a restart** keeps the overview numbers (Task 1:
   `notModifiedKeepsStats`).
5. **An unknown stored period** (e.g. 14, hand-edited) falls back to 30
   (Task 3: `periodDecodesTolerantly`).

---

### Task 1: Stats from the repository listing

**Files:**
- Modify:
  - `Packages/RadarixKit/Sources/RadarixKit/Model/Repo.swift` (add `RepoStats`, `RepoListing`)
  - `GitHub/APIModels.swift` (`RepoDTO`)
  - `GitHub/GitHubAPI.swift` (`repositories(of:)`)
  - `Sync/SyncEngine.swift` (`Resolution.stats`, `resolve`)
  - `Model/Settings.swift` (`AccountData.stats`, schema 4)
  - `Controller/AccountSession.swift` (merge and save)
  - `Controller/RadarixController.swift` (`repoStats(_:)`)
  - `Tests/.../Support/StubGitHubAPI.swift`
- Test:
  - `GitHubAPITests.swift`, `SyncEngineTests.swift`, `SchemaEvolutionTests.swift`, `RadarixControllerTests.swift`;
  - the fixture `Fixtures/repos.json` gains `stargazers_count`, `forks_count`, `open_issues_count`, `pushed_at`, `description`, `language` on its first entry. The second entry stays without them.

**Interfaces:**

- Produces:
  ```swift
  public struct RepoStats: Sendable, Codable, Hashable {
      public var stars: Int; public var forks: Int; public var openIssuesAndPulls: Int
      public var pushedAt: Date?; public var description: String?; public var language: String?
  }
  public struct RepoListing: Sendable, Equatable { public let ref: RepoRef; public let stats: RepoStats }
  // GitHubAPI protocol + client:
  func repositories(of owner: OwnerRef) async throws -> Fetch<[RepoListing]>
  // Resolution:
  public var stats: [RepoID: RepoStats]   // only from fresh listings
  // AccountData:
  public var stats: [RepoID: RepoStats] = [:]
  // RadarixController:
  public func repoStats(_ id: RepoID) -> RepoStats?   // from the owning session's account
  ```
- **`RepoDTO` decoding:** the new count fields are optional. A missing count
  decodes as 0.
- **`RepoRef` stays unchanged.**
- **Stub:** keep the existing helper that takes `[RepoRef]`. It wraps each
  one in a `RepoListing` with zero stats, so existing tests stay as they are.
  Add an overload that takes `[RepoListing]`.

**Steps:**

- [ ] **Step 1: Write the failing tests.**
  - `repositoriesDecodeStats`: the listing fixture gives stars 1420, forks 87, open 12 and the language "Swift" for `hello-world`, and zero counts for `secret-sauce`.
  - `resolveCollectsStats` (SyncEngineTests): a fresh listing fills `resolution.stats[id]`.
  - `notModifiedKeepsStats`:
    - a session with stored `account.stats` gets a `.notModified` listing;
    - after `resolve` the stats are unchanged and still saved.
  - `freshStatsAreSaved`: changed stars in a fresh listing land in `account.stats` and are persisted.
  - `statsOfUnlistedReposArePruned`: a repository missing from every fresh listing of its owner drops out of `account.stats`.
  - `accountV3DecodesWithoutStats` (SchemaEvolutionTests): `plan1-account.json` decodes with `stats == [:]`.
  - `repoStatsComeFromOwner` (RadarixControllerTests): two accounts both list a repository; `repoStats` returns the owner's numbers.
- [ ] **Step 2:** run `swift test --filter "Stats"`. Expected: it fails to compile or the tests fail.
- [ ] **Step 3: Implement.**
  - `SyncEngine.resolve` keeps `available[owner] = listings.map(\.ref)` and merges the stats into `resolution.stats`.
  - **`AccountSession`:**
    - on resolve, `account.stats` = the old stats, overwritten by `resolution.stats`;
    - then filtered to the IDs present in `account.available`;
    - saved when this changed, in both branches where `account.available` is set today.
  - `AccountData.currentSchemaVersion = 4`; encode and decode `stats`.
- [ ] **Step 4:** run `swift test`. Expected: all pass, about 310 tests.
- [ ] **Step 5:** commit `feat: keep repository stats from the listing`.

### Task 2: GraphQL client and repository insights

**Files:**
- Create: `Packages/RadarixKit/Sources/RadarixKit/GitHub/RepoInsights.swift` (types, query text, parsing)
- Modify:
  - `GitHub/GitHubClient.swift` (`graphQL`)
  - `GitHub/GitHubAPI.swift` (protocol + `insights`)
  - `Controller/AccountSession.swift` (the unauthorized stub at the bottom of the file, plus a pass-through)
  - `Tests/.../Support/StubGitHubAPI.swift`
- Test: `Packages/RadarixKit/Tests/RadarixKitTests/RepoInsightsTests.swift` (new)

**Interfaces:**

- Produces:
  ```swift
  // GitHubClient
  public func graphQL<T: Decodable>(_ query: String, variables: [String: String]) async throws -> T
  // RepoInsights.swift
  public struct PeriodCount: Sendable, Equatable { public var value: Int; public var atLeast: Bool }
  public enum PeriodMetric: String, Sendable, CaseIterable { case stars, forks, openedIssues, openedPulls, mergedPulls }
  public struct Release: Sendable, Equatable { public var name: String?; public var tag: String; public var publishedAt: Date? }
  public struct RepoInsights: Sendable, Equatable {
      public var description: String?; public var language: String?; public var license: String?; public var topics: [String]
      public var stars: Int; public var forks: Int; public var watchers: Int
      public var openIssues: Int; public var openPulls: Int
      public var latestRelease: Release?
      public var period: [PeriodMetric: PeriodCount]
  }
  // GitHubAPI protocol + client
  func insights(for repo: RepoRef, since: Date) async throws -> RepoInsights
  // AccountSession
  public func insights(for repo: RepoRef, since: Date) async throws -> RepoInsights
  ```
- **`graphQL`:**
  - It posts `{"query":…, "variables":…}` to `/graphql` through `perform`, with `method: "POST"`.
  - It passes a new `perform` flag, `tracksRateLimit: false`.
  - It decodes the envelope `{ data: T?, errors: [{ type: String?, message: String }]? }`.
  - **Errors:** a non-empty `errors` throws.
    - type `"NOT_FOUND"` maps to `.notFound`;
    - `"RATE_LIMITED"` maps to `.rateLimited(resetAt:)`, from `X-RateLimit-Reset` if present, else now + 60 s;
    - any other type maps to `.decoding(first message)`.
  - A null `data` without `errors` maps to `.decoding`.
  - HTTP errors map through `perform` as today.
- **The query**: exact text, kept as a `static let` in `RepoInsights.swift`.
  ```graphql
  query($owner: String!, $name: String!, $issues: String!, $pulls: String!, $merged: String!) {
    repository(owner: $owner, name: $name) {
      description
      primaryLanguage { name }
      licenseInfo { spdxId name }
      repositoryTopics(first: 20) { nodes { topic { name } } }
      stargazerCount
      forkCount
      watchers { totalCount }
      issues(states: OPEN) { totalCount }
      pullRequests(states: OPEN) { totalCount }
      latestRelease { name tagName publishedAt }
      stargazers(first: 100, orderBy: {field: STARRED_AT, direction: DESC}) { pageInfo { hasNextPage endCursor } edges { starredAt } }
      forks(first: 100, orderBy: {field: CREATED_AT, direction: DESC}) { pageInfo { hasNextPage endCursor } nodes { createdAt } }
    }
    openedIssues: search(query: $issues, type: ISSUE, first: 1) { issueCount }
    openedPulls: search(query: $pulls, type: ISSUE, first: 1) { issueCount }
    mergedPulls: search(query: $merged, type: ISSUE, first: 1) { issueCount }
  }
  ```
  - **Follow-up pages:** two small queries that take `$owner`, `$name` and `$after`. They select only `repository { stargazers(first: 100, after: $after, orderBy: …) { pageInfo edges { starredAt } } }` or the same for `forks … nodes { createdAt }`.
  - **Search strings:** `day` is `since` formatted as `yyyy-MM-dd` in UTC.
    - `repo:OWNER/NAME is:issue created:>=DAY`
    - `repo:OWNER/NAME is:pr created:>=DAY`
    - `repo:OWNER/NAME is:pr is:merged merged:>=DAY`
  - **License:** `spdxId` if it is present and not `"NOASSERTION"`, else `name`.
- **Counting stars and forks:**
  - Count the entries with date ≥ `since` on each page.
  - Fetch the next page only while every entry on the current page is ≥ `since`, `hasNextPage` is true, and fewer than 5 pages have been read.
  - If the 5th page is entirely inside the period and `hasNextPage` is true, then `atLeast = true`, with value 500.
  - The search counts are always `atLeast: false`.

**Steps:**

- [ ] **Step 1: Write the failing tests** in `RepoInsightsTests.swift`. They use `StubTransport` on `https://api.github.com/graphql`, and the stub's per-URL queue serves successive pages.
  - `insightsSendsOneQuery`:
    - exactly one POST;
    - the body's `variables` are `owner: "octo"`, `name: "hello-world"`, and `issues: "repo:octo/hello-world is:issue created:>=2026-10-26"` for `since = 2026-10-26T08:00:00Z`;
    - `Authorization: Bearer tok`.
  - `insightsDecodesCounts`:
    - stars 1420, forks 87, watchers 31, open issues 9, open pulls 3;
    - release tag `v2.0.0`; license `MIT`; topics `["swift","macos"]`;
    - period: openedIssues 4, openedPulls 6, mergedPulls 5.
  - `starsCountedWithinPeriod`: 3 of 5 stargazer edges are ≥ `since` → `stars == PeriodCount(value: 3, atLeast: false)`, and there is no second request.
  - `starsFollowNextPage`:
    - the first page holds 100 edges, all in the period, with `hasNextPage` set;
    - the second page holds 20 in the period and 5 before it;
    - result: value 120, 2 requests, and the second body's `variables.after` equals the first `endCursor`.
  - `starsCappedAtFivePages`: 5 full in-period pages with `hasNextPage` → value 500, `atLeast` true, exactly 5 requests.
  - `forksCountedWithinPeriod`: the same shape as the stars test, on `forks.nodes.createdAt`.
  - `graphQLNotFoundMaps`: HTTP 200 with `{"data":{"repository":null,…},"errors":[{"type":"NOT_FOUND","message":"x"}]}` → throws `GitHubError.notFound`.
  - `graphQLRateLimitedMaps`: 200 with `errors` type `RATE_LIMITED` and header `X-RateLimit-Reset: 1900000000` → throws `.rateLimited(resetAt: Date(timeIntervalSince1970: 1900000000))`.
  - `graphQLLeavesRateLimit`:
    - a REST GET with headers remaining 4000 / limit 5000 sets `latestRateLimit`;
    - a following GraphQL reply with remaining 10 leaves it at 4000.
  - `licenseNoAssertionUsesName`: `spdxId: "NOASSERTION"`, `name: "Other"` → license `"Other"`.
- [ ] **Step 2:** run `swift test --filter RepoInsights`. Expected: it fails.
- [ ] **Step 3: Implement** the interfaces above.
  - The response DTOs are private to `RepoInsights.swift`.
  - Dates are ISO 8601 and decode through the client's existing decoder.
  - The stub gains `insightsResults: [RepoID: Result<RepoInsights, GitHubError>]` and records `.insights(repo:since:)`.
- [ ] **Step 4:** run `swift test`. Expected: all pass.
- [ ] **Step 5:** commit `feat: load repository insights in one GraphQL query`.

### Task 3: Controller and period setting

**Files:**
- Modify:
  - `Model/Settings.swift` (`repoInfoPeriodDays`, schema 6)
  - `Controller/RadarixController.swift`
- Test: `RadarixControllerTests.swift`, `SchemaEvolutionTests.swift`

**Interfaces:**

- Produces:
  ```swift
  public enum InsightsError: Error { case noOwner }            // declared above RadarixController's doc comment, like DescriptionError
  public static let repoInfoPeriods = [7, 30, 90]              // on AppSettings
  public var repoInfoPeriodDays: Int = 30                      // AppSettings
  public func insights(for id: RepoID, days: Int) async throws -> RepoInsights   // RadarixController
  ```
- **`insights`:** `since = now() - days × 86 400 s`, using the controller's injected `now`. It goes through `owner(of:)`, and `repos[id]?.repo` or the owner's `watchedRepos()` for the `RepoRef`.

**Steps:**

- [ ] **Step 1: Write the failing tests.**
  - `insightsUsesOwnerAndPeriod`: with `now` fixed at 2026-11-25T00:00:00Z and `days: 30`, the stub records `since == 2026-10-26T00:00:00Z` on the owner's API only.
  - `insightsWithoutOwnerThrows`: an unknown `RepoID` → `InsightsError.noOwner`.
  - `periodDefaultsTo30`: `AppSettings()` gives 30, and `plan2-settings.json` decodes to 30.
  - `periodDecodesTolerantly`: a stored 14 → 30; a stored 90 → 90.
  - `periodRoundTrips`: `updateSettings { $0.repoInfoPeriodDays = 7 }`, then reload from the store → 7.
- [ ] **Step 2:** run `swift test --filter "insights|period"`. Expected: it fails.
- [ ] **Step 3: Implement.** The decoder maps any value outside `repoInfoPeriods` to 30. Set `AppSettings.currentSchemaVersion = 6`.
- [ ] **Step 4:** run `swift test`. Expected: all pass.
- [ ] **Step 5:** commit `feat: repository insights for the owning account`.

### Task 4: Repository info window

**Files:**
- Create: `App/RepoInfo/RepoInfoWindow.swift`
- Modify:
  - `App/RadarixApp.swift` (scene)
  - `App/WindowTracker.swift` (`case repoInfo`)
  - `App/Main/MainWindow.swift` (`ItemActions.showRepoInfo`, wired to `openWindow(id: "repo-info", value:)`)
  - `App/Main/SidebarLayout.swift` (`RepoContextMenu`)
  - `App/AppModel.swift` (message for `InsightsError`)
  - `App/Resources/Localizable.xcstrings`

**Interfaces:**

- Consumes: `controller.repoStats(_:)` (Task 1), `controller.insights(for:days:)` and `settings.repoInfoPeriodDays` (Task 3), `RepoInsights`/`PeriodMetric` (Task 2).
- Produces: `ItemActions.showRepoInfo: @MainActor (RepoID) -> Void`, used by Task 5 too.

**Steps:**

- [ ] **Step 1: Add the scene.**
  - `WindowGroup(id: "repo-info", for: RepoID.self)`, with the same modifiers as the description scene: `.commandsRemoved()`, `.defaultLaunchBehavior(.suppressed)`, `.restorationBehavior(.disabled)` and `.handlesExternalEvents(matching: [])`.
  - Default size 520 × 560.
  - `WindowMarker(kind: .repoInfo, tracker:)`.
- [ ] **Step 2: Add the context menu entry.** "Repository Info…" goes in `RepoContextMenu`, after "Refresh repository". It calls `actions.showRepoInfo(section.id)`.
- [ ] **Step 3: Build the window.** The layout is the builder's call within spec §3.
  - **Header:** `owner/name`, description, language, license, topics as small capsules, and an "Open on GitHub" button.
  - **"Now":** a grid of stars, forks, watchers, open issues, open pull requests and the latest release (tag and relative date).
  - **"In the last" period picker:** a segmented `Picker` over `AppSettings.repoInfoPeriods`, with labels "7 days", "30 days" and "90 days".
    - Bind it with closures to `controller.updateSettings`.
    - The rows are new stars, new forks, opened issues, opened pull requests and merged pull requests.
    - An `atLeast` value renders as "500+".
  - **Before the first answer:** show `repoStats` (stars, forks, open issues & PRs) and a `ProgressView` in place of the rest.
  - **Loading:** `.task(id: period)` loads, with a `Task.isCancelled` guard after the await. A failure keeps the shown values and adds an error line with "Try again".
  - **Window title:** `owner/name`.
- [ ] **Step 4: Error messages.** `AppModel.message(for:)` gains:
  - `InsightsError.noOwner` → "Not signed in to an account that watches this repository.";
  - inside the window, `GitHubError.notFound` → "This repository can't be read with this sign-in.".
- [ ] **Step 5: Strings.** Add every new string to the catalog in en, de, fr and pl, with plural variants for the "%lld days" and count labels where needed.
- [ ] **Step 6: Build.** Run the app build command. Expected: `BUILD SUCCEEDED` and no new warnings (`grep -c "warning:"` equals the count before).
- [ ] **Step 7:** commit `feat: repository info window`.

### Task 5: Repository overview window

**Files:**
- Create: `App/RepoInfo/RepoOverviewWindow.swift`
- Modify:
  - `App/RadarixApp.swift` (the `Window` scene, plus a `CommandGroup(before: .windowList)` with "Repository Overview" and ⌘⇧O)
  - `App/WindowTracker.swift` (`case overview`)
  - `App/Resources/Localizable.xcstrings`

**Interfaces:**

- Consumes:
  - `controller.repoStats(_:)`;
  - the watched repositories in sidebar order, built the same way `MainWindow.accountSections` orders them (reuse it, don't duplicate the ordering);
  - `openWindow(id: "repo-info", value: RepoID)`.

**Steps:**

- [ ] **Step 1: Add the scene.**
  - `Window("Repository Overview", id: "repo-overview")`, with `.defaultLaunchBehavior(.suppressed)` and `.restorationBehavior(.disabled)`.
  - `WindowMarker(kind: .overview, …)`.
  - Default size 720 × 480.
- [ ] **Step 2: Build the table.** A `Table` with `sortOrder` and these columns:
  - Repository (`owner/name`, archived or private shown as a small symbol);
  - Stars, Forks, "Open issues & PRs";
  - Last push (relative).
  - Missing stats render "—" and sort last.
  - **The empty state:** "No repositories yet. Radarix fills this in after the first sync."
- [ ] **Step 3: Row actions.** Double-click (`.contextMenu(forSelectionType:primaryAction:)`) and Return open the info window. The context menu has "Repository Info…" and "Open on GitHub".
- [ ] **Step 4: Strings.** Add them in en, de, fr and pl.
- [ ] **Step 5: Build.** Run the app build. Expected: `BUILD SUCCEEDED` and no new warnings.
- [ ] **Step 6:** commit `feat: repository overview window`.

### Task 6: User docs and website

Both of these go on branches in their own repositories and are not merged:

- `~/_dev/noix-docs`: branch `docs/radarix-repo-info` from `main`.
- `~/_dev/noix.dev`: branch `radarix-repo-info` from `main`.

**Steps:**

- [ ] **Step 1: noix-docs.**
  - Add a page `src/content/docs/radarix/guide/repository-info.md`, with frontmatter `title`, a one-sentence `description` and `sidebar.order` after the main window page. It covers:
    - how to open it (context menu, Window → Repository Overview, ⌘⇧O);
    - what the numbers mean;
    - periods;
    - "500+";
    - why watchers have no "new";
    - that private repositories need the sign-in's read access.
  - Link it from the main window page.
- [ ] **Step 2: Check noix-docs.** Run `npm run check && npm run build`. Expected: 0 errors, and `dist/llms.txt` lists the page.
- [ ] **Step 3: noix.dev.** Add one feature bullet to `src/content/projects/{de,en}/radarix.md`, in each language's existing style, with no tech-stack terms.
- [ ] **Step 4:** commit `docs(radarix): describe repository info` and `feat(radarix): mention repository info` in each repository.
