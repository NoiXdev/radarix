# Radarix 1.1 refinements: design

Status: draft for the owner's approval, 2026-11-24.
Base: Radarix 1.0.0 (`main` at f0cb405). Specs it builds on:
`2026-11-24-radarix-design.md`, `2026-11-24-radarix-multi-account-design.md`.

## Intent

The owner uses Radarix every day and asked for five changes:

- Filters should survive a restart.
- Each widget should be able to show a filtered set.
- The sidebar should say at a glance how many PRs and how many issues are
  waiting.
- "All" should be readable when many repositories are watched.
- An item's description should be readable as GitHub shows it, not as raw
  text squeezed into the inspector.

None of this is new ground. Each change makes something that exists today work
the way the owner expects. Success means the app keeps the owner's setup
across launches, the widget answers "is there anything for me?", and nobody
has to open github.com just to read a description.

## Goals

1. **Persisted filters.** The filter chips and the Bots chip are kept across
   app restarts, for the whole app.
2. **Widget filters.** Each widget has the same filters as the filter bar,
   next to its repository choice.
3. **Sidebar badges by kind.** Each repository in the sidebar, and "All",
   shows its counts split into pull requests and issues. Each count is
   colored by kind and still tells new from updated.
4. **Group "All" by repository.** In the sidebar layout, "All" can show one
   section per repository.
5. **Rendered description in its own window.** The full description is
   loaded from GitHub, already rendered, and shown in a separate window.

## Non-goals

- Named or saved filter presets. One current filter is all that is kept.
- Per-window filters. Today's per-window storage goes away.
- Comments, the timeline or review threads in the description window. It
  shows only the item's description.
- Editing or replying.
- A native Markdown renderer.
- Changing what a double click does. It still opens the item on GitHub.

## Anti-goals

The design has failed, even if it works, if:

- the description window runs page JavaScript or navigates inside itself to
  other sites;
- the description window sends a token to any host other than
  `api.github.com`;
- the widget snapshot gains account ids, credentials or other people's
  logins (it holds today only what the widget shows);
- the sidebar loses the new/updated distinction, which is the core of the
  app.

## Constraints

- The project's existing constraints apply: Swift 6 strict concurrency,
  macOS 15, no new warnings, Swift Testing in `RadarixKit`, English and
  German strings in the catalogs, and builds on both Xcode 26.6 / Swift 6.3
  (the CI runner) and Xcode 27.
- New persisted fields use `decodeIfPresent` with defaults. A 1.0.0
  `settings.json` and a 1.0.0 widget snapshot must still load. An older
  widget reading a newer snapshot is not a concern, because both ship in one
  bundle.
- The widget is sandboxed and reads only the shared snapshot. It makes no
  network calls.

## Approaches (rendering the description)

1. **GitHub's rendered HTML in an embedded web view (chosen by the owner).**
   - Fetch the item with the HTML media type, which gives `body_html`. GitHub
     has already rendered and sanitized it.
   - Show it in a web view with JavaScript off and our own stylesheet.
   - The result matches github.com: tables, task lists, code, images,
     mentions and inline HTML.
   - Cost: one request per open. Offline, only the stored excerpt is shown.
2. **Render the Markdown natively.** Fetch the raw body and render it in the
   app. There is no web content, but tables, inline HTML and GitHub extensions
   are lost. That is the problem the owner wants solved. Rejected.
3. **Show the raw text in a bigger window.** This does not render anything.
   Rejected.

## Design

### 1. Persisted filters

- `AppSettings` gains:
  - `filter: FilterSet`, defaulting to `FilterSet()`;
  - `showsBots: Bool`, defaulting to `false`.
- `MainWindow` reads and writes these through the controller. The
  `@SceneStorage("main.filter")` and `("main.showsBots")` storage is removed.
- Migrating the old per-window values is not needed. The first launch of 1.1
  starts from the defaults.
- `FilterSet` needs a tolerant decoder, so that a later new chip does not
  reset the whole settings file.

### 2. Widget filters

- `ScopeIntent` gains parameters next to `scope`:
  - **Attention:** "New" and "Updated" (both on by default);
  - **Assignment:** "Unassigned", "Assigned to me", "Review requested" (all
    off by default);
  - **Kind:** "Pull requests" and "Issues" (both off by default, which means
    both kinds).
- The combination rules are those of `FilterSet` and `ItemFilter.matches`:
  flags in one group are ORed, and groups are ANDed. Use a single shared
  function, not a copy of the logic.
- Each widget instance has its own settings, as with `scope`.
- **Snapshot changes.**
  - `WidgetSnapshot.ItemEntry` gains three booleans:
    - `isUnassigned`;
    - `isAssignedToViewer`;
    - `isReviewRequestedFromViewer`.
  - "Viewer" means any signed-in account, the same `ViewerLogins` the main
    list uses. The snapshot gains no logins.
  - Today the snapshot keeps only the newest 6 items per repository, but the
    counts are taken over all of them. A filtered widget must count and list
    from the filtered items, so the snapshot has to carry every new and
    updated item, not just the first 6.
  - The builder sets a size cap, so the snapshot stays small with many
    repositories. Record the cap in the code.
  - If the cap cuts items off, the widget's counts must say so or stay
    correct. Truncation must never make them silently wrong.
- **What the widget shows:** the counts and the list come from the filtered
  items.
  - The bot rule stays as today, following the app's bot display setting.
  - A filter that leaves nothing shows the existing "nothing new" state.
  - The widget states that a filter is active in its existing
    subtitle/caption area, for example "Assigned to me · PRs". The wording is
    the builder's call.

### 3. Sidebar badges by kind (owner's choice: kind and attention)

- Each sidebar row (repository and "All") shows up to two badges: pull
  requests and issues.
  - Each badge is a capsule with the kind's glyph and the count of new plus
    updated items of that kind. Its tint is the kind color.
  - A small attention dot sits on or beside the badge. It is blue when at
    least one item of that kind is new, and amber when there are only
    updated items. These are the existing `attentionNew` and
    `attentionUpdated` colors.
  - The VoiceOver label reads, for example, "3 pull requests, 1 new, 2
    updated".
- **Kind colors:** these are the builder's call, within these rules.
  - They must differ clearly from the attention blue and amber.
  - They must also differ from the status colors on item rows (green open,
    purple merged, red closed).
  - Both must work in light and dark mode.
- **Counts:** they follow the same rules as today's counts, meaning listed
  items and the bot display mode. They do not depend on the filter chips, as
  today.
- **Grouped layout:** its section headers use the same badges, so both
  layouts look alike.
- `AttentionCounts` grows per-kind numbers, or a sibling type does. That is
  the builder's call. The menu bar and the widget keep using the totals.

### 4. Group "All" by repository

- In the sidebar layout, with "All" selected, a toolbar toggle "Group by
  repository" shows the item list with one section per repository.
  - The headers are the same as in the grouped layout: `owner / name` and the
    badges.
  - Sections are in sidebar order. Empty sections are hidden.
- The toggle is stored as `AppSettings.groupAllByRepo: Bool`, default
  `false`.
- It only appears with "All" selected in the sidebar layout. A single
  repository is already one group.
- Selection, keyboard navigation, the context menu and deep links (scrolling
  to an item) work the same as in the flat list.
- Reuse the grouped layout's section rendering rather than building a second
  one.

### 5. Description window

- **How to open it:**
  - a "Show description" button in the inspector, which replaces today's
    inline excerpt;
  - "Show Description" in the item context menu;
  - the Space key on the selected item (Quick Look style). Pressing Space
    again, or Escape, closes the window.
- **The window:**
  - a separate, resizable window (a `Window`/`WindowGroup` keyed by the item);
  - opening the same item again brings its window to the front;
  - title "`owner/name` #number";
  - a header with the item's title, kind and status, and an "Open on GitHub"
    button.
- **Loading:**
  - The window sends `GET /repos/{owner}/{repo}/issues/{number}` with
    `Accept: application/vnd.github.html+json`, using the token of the
    account the item belongs to. The issues endpoint serves pull requests too.
  - While the request runs, the window shows the stored excerpt with a
    progress indicator.
  - On failure (offline, 404, rate limit) it keeps the excerpt and shows a
    one-line error with "Try again".
  - An empty body shows "No description."
- **The web view:**
  - JavaScript is off, through `WKWebpagePreferences.allowsContentJavaScript
    = false`.
  - Every navigation other than the initial load is cancelled. Clicked
    `http(s)` links open in the default browser.
  - The HTML is wrapped in our own page, with a stylesheet that follows the
    system font, light and dark mode, and GitHub-like basics (code blocks,
    tables, task lists, images scaled to width). The base URL is
    `https://github.com/owner/name/` so relative links resolve.
  - No cookies or website data persist: use a non-persistent data store.
- **Marking seen:** opening the window marks the item seen, like selecting
  it.
- The fetch lives in `RadarixKit`, with a test for the request (path, accept
  header, token) and for decoding `body_html`. It is not persisted, and the
  sync is unaffected.

## Calls made in the design (not the owner's words)

- **Widget with "New" and "Updated" both off.** In the main list this means
  "any attention, including seen". The snapshot never holds seen items, so
  for the widget both-off counts as both-on.
- **Images in the description window are loaded.** They come from GitHub's
  image proxy or signed URLs in `body_html` and carry no token. The app is
  not sandboxed, so nothing extra is needed.
- **Double click still opens the item on GitHub.** The window opens with
  Space, the inspector button or the context menu.
- **No migration of the old per-window filters.**

## Left to the builder

- Kind colors, within the rules in section 3.
- The snapshot size cap, and how truncation is shown.
- The widget's wording for an active filter.
- The shape of the per-kind counts type.
- The description window's stylesheet details.
- Whether "Show description" also gets a keyboard shortcut besides Space.

## Docs

- Update the Radarix user docs in `noix-docs` in the same cycle:
  - main window (grouping, description window);
  - menu bar (badges);
  - widget (filters);
  - settings (persisted filters).
- The docs branch `docs/radarix` is not merged yet. Build on it, or on
  `main` once it is merged.
