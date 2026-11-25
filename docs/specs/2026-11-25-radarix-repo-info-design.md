# Radarix 1.3: repository info. Design

Status: the owner asked for it and said "mach mal" (go ahead), 2026-11-25.
Base: Radarix 1.2.0 plus the fr/pl translations (`main` at d18c319).

## Intent

The owner wants to see how a repository is doing, meaning its stars, forks
and watchers, without opening github.com. They also want to see what changed
recently, as in "x new in the last x days". The owner's words: "Fenster mit
den Zahlen und drunter den x neuen in den x Tagen".

They asked for both:

- one window per repository, opened from the repository context menu;
- one overview of all watched repositories.

This info lives in its own windows and never in the item list.

## Goals

1. **Repository info window.**
   - Open it with "Repository Info…" in the repository context menu, both in
     the sidebar row and in the grouped section header.
   - **Current numbers:** stars, forks, watchers, open issues, open pull
     requests and the latest release.
   - **"In the last N days":** new stars, new forks, opened issues, opened
     pull requests and merged pull requests.
   - **Period:** a picker with 7, 30 or 90 days. The default is 30. It is
     stored as `AppSettings.repoInfoPeriodDays` and decoded tolerantly.
   - **Header:** `owner/name`, the description, the primary language, the
     licence, the topics, and "Open on GitHub".
2. **Repository overview window.**
   - Open it from **Window → Repository Overview**.
   - It is one table of all watched repositories, in sidebar order. The
     columns are repository, stars, forks, open issues & PRs (combined,
     GitHub's own number) and last push.
   - The columns are sortable.
   - Double-clicking a row opens that repository's info window.
3. **Docs and website.**
   - Update the Radarix guide in noix-docs: the main window, and a new
     "Repository info" section.
   - Add one bullet to the noix.dev project page (DE and EN).
   - Merging and pushing happen only on the owner's word.

## Non-goals

- Charts or a stored history over time.
- Traffic (views, clones). GitHub gives those only with write access and only
  for 14 days.
- Contributors, the code frequency graph, Discussions.
- Repositories that are not watched.
- Any write.

## Anti-goals

The design has failed if:

- a sync pass becomes slower or costs more requests;
- the window sends a token to any host other than `api.github.com`;
- a number appears as exact when it was cut off (see "Caps");
- a failed load blanks numbers that were already shown.

## Constraints

- The project's existing constraints apply:
  - Swift 6 strict concurrency;
  - macOS 15;
  - Swift Testing in `RadarixKit`;
  - no new warnings;
  - the build must pass on Xcode 26.6 / Swift 6.3 (the CI runner) and on Xcode 27;
  - no method references as Binding setters.
- **Strings:** every new UI string goes into `App/Resources/Localizable.xcstrings`
  in en, de, fr and pl.
- **Persisted fields:** they decode with defaults. A 1.2 `settings.json` and
  an account file must still load.
- **Requests:** use the owning account's session, as for the description and
  for assigning. A repository without an owner shows "Not signed in".

## Approaches (how the window gets its numbers)

1. **One GraphQL query when the window opens (my call, chosen).**
   - `POST /graphql` on `api.github.com` with the owning account's token.
   - One query returns everything:
     - the counts (`stargazerCount`, `forkCount`, `watchers.totalCount`,
       `issues(states: OPEN)`, `pullRequests(states: OPEN)`);
     - `latestRelease`;
     - stars sorted newest first (`stargazers(orderBy: {field: STARRED_AT,
       direction: DESC})`);
     - forks sorted newest first (`forks(orderBy: {field: CREATED_AT,
       direction: DESC})`);
     - three aliased `search(type: ISSUE)` counts for the period.
   - **Cost:** usually one request. It needs no stored history and is exact
     from the first day.
   - **Price:** Radarix gains its first GraphQL call, so the client must
     handle GraphQL errors.
2. **REST.**
   - `GET /repos/{o}/{n}`, stargazers with `starred_at` (oldest first, so
     the client has to walk back from the last page), forks, and four
     `search/issues` calls.
   - That is 7 or more requests per open, and the search API is limited to
     30 per minute.
   - It works, but it is slow and it uses up the limit.
3. **Local history from the sync.**
   - Store the daily counts that the repository listing already brings, then
     subtract.
   - It is free, but it shows nothing until N days have passed, it has no
     watchers, and it only gives net change.
   - This contradicts "x new in x days" for a new install.

**For the overview:** it uses the counts that the existing repository
listing already returns (`stargazers_count`, `forks_count`,
`open_issues_count`, `pushed_at`). Today Radarix decodes them and throws them
away. They cost no request and survive a restart because they are stored with
the listing.

## Design

### 1. Overview data from the listing

- `RepoDTO` decodes:
  - `stargazers_count`, `forks_count`, `open_issues_count`;
  - `pushed_at`, `description`, `language`.
- They go into a separate value, `RepoStats`, keyed by `RepoID`. Do **not**
  add them to `RepoRef`: `RepoRef` is the repository's identity, and it is
  compared and hashed across sync.
- `RepoStats` is stored per account next to `available`, as
  `AccountData.stats: [RepoID: RepoStats]`. It decodes with `[:]` as the
  default.
- A `.notModified` listing keeps the stored stats.
- The controller exposes `repoStats(_ id: RepoID) -> RepoStats?`. The
  overview reads only this and sends no request.

### 2. Info window data (`RepoInsights`)

- **Kit API:**
  `GitHubAPI.insights(for repo: RepoRef, since: Date) async throws -> RepoInsights`.
- **The query:**
  - one GraphQL query for `repository(owner:, name:)`, using variables for
    the owner, the name and three search strings;
  - the search strings are `repo:o/n is:issue created:>=YYYY-MM-DD`,
    `repo:o/n is:pr created:>=…` and `repo:o/n is:pr is:merged merged:>=…`,
    with dates in UTC.
- **Counting stars and forks in the period:**
  - Take up to 100 per page, newest first. Count the entries at or after
    `since`.
  - If the whole page is inside the period, fetch the next page with the
    cursor. Only stargazers or forks are fetched on these pages, not the
    whole query.
- **Caps:**
  - Stop after 5 pages (500). The count is then marked `atLeast`, and the UI
    shows "500+".
  - The search counts are exact up to GitHub's search limit. Use the
    `issueCount` as given.
- **`GitHubClient`** gains `graphQL<T: Decodable>(_ query: String, variables:
  [String: String]) async throws -> T`.
  - It posts to `/graphql` on the existing `baseURL`, with the same headers,
    rate-limit tracking and HTTP error mapping as `send`.
  - A response with `errors` throws:
    - type `NOT_FOUND` maps to `.notFound`;
    - `RATE_LIMITED` maps to `.rateLimited`, using the reset header if it is
      present, otherwise now + 60 s;
    - anything else maps to `.decoding(message)`.
- **The result type:**
  - `RepoInsights` has the current counts, an optional latest release (name,
    tag, `publishedAt`) and the header fields;
  - plus `period: [PeriodCount]` for `.stars`, `.forks`, `.openedIssues`,
    `.openedPulls` and `.mergedPulls`;
  - each `PeriodCount` has a `value: Int` and `atLeast: Bool`.
- **Controller:** `RadarixController.insights(for id: RepoID, days: Int) async throws -> RepoInsights`.
  - It uses the owning session.
  - It throws `InsightsError.noOwner` when no session owns the repository.
  - Nothing is persisted.

### 3. The info window

- `WindowGroup(id: "repo-info", for: RepoID.self)`, with `.commandsRemoved()`
  like the description window.
- Opening the same repository again brings its window to the front.
- The title is `owner/name`.
- **Layout (builder's call within this):**
  - the header;
  - a grid of current numbers, each with an SF Symbol;
  - below it, "In the last [7 | 30 | 90] days" with the five period counts.
- **While loading:**
  - show the listing's `RepoStats` (stars, forks, open issues & PRs) right
    away;
  - show a spinner where the rest goes;
  - changing the period reloads. The previous load is cancelled. There is a
    `Task.isCancelled` guard after the await, as in `DescriptionContent`.
- **On failure:**
  - keep what is shown and add a one-line error with "Try again";
  - the messages come from `AppModel.message(for:)`;
  - "not found" reads "This repository can't be read with this sign-in".
- **`WindowTracker`** gains a `repoInfo` marker. The window counts for "Hide
  from the Dock" like the description window.

### 4. The overview window

- `Window("Repository Overview", id: "repo-overview")`, which is a single
  window.
- It is in the Window menu through `CommandGroup`. The builder picks a
  shortcut that is not taken; ⌘⇧O is suggested.
- It is a SwiftUI `Table` with sortable columns:
  - repository (`owner/name`);
  - stars, forks, open issues & PRs;
  - last push, as a relative date.
- A repository with no stats yet shows "—".
- Double-click or Return opens the info window. The context menu has
  "Repository Info…" and "Open on GitHub".
- It is empty until the first sync, with a short empty state.
- `WindowTracker` gains an `overview` marker.

## Calls made (not the owner's words)

- GraphQL on open for the info window. The listing counts serve the overview.
- The periods are 7, 30 and 90 days, with 30 as the default. The setting is
  app-wide, not per window.
- "Open issues" in the overview is GitHub's combined issues & PRs number,
  because that is what the listing gives at no cost. The info window shows
  them split.
- The cap is 500 for stars and forks per period, shown as "500+".
- Watchers have no "new in period", because GitHub keeps no dates for
  watching.

## Left to the builder

- The exact layout, the symbols and the overview shortcut.
- The names of the private helper types.
