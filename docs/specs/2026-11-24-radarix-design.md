# Radarix: design

Status: draft for approval · 2026-11-24
Working folder: `~/_dev/git-overview` (working title only, see Naming)

## Intent

Radarix is a native macOS app that answers one question at a glance:
**"Has anything happened in my projects?"** The owner maintains many
repositories on GitHub (the NoiXdev org plus repos in other orgs). Today they
have to open each repo to see whether a new issue or pull request arrived or
whether something they already looked at moved on. Radarix watches a chosen
set of repositories, marks what is new or updated since the user last looked,
and surfaces that in a main window, the menu bar, notifications and desktop
widgets.

It is a personal tool first, published like the other NoiXdev Mac apps
(open source, free).

## Goals

1. Sign in to GitHub so private repositories are visible and the
   authenticated rate limit applies.
2. Choose which repositories are watched, per owner (user account or org).
3. Show every watched repo's open issues and pull requests, with each item
   marked **new**, **updated** or **seen**, and filterable so the user can
   quickly find what needs attention.
4. Tell the user about new items without them opening the app: a menu bar
   icon with a count, per-repo notifications, desktop widgets.
5. Ship with a name, logo, user documentation, a project page on noix.dev
   and a launch post.

## Non-goals (v1)

- Anything other than issues and pull requests. CI runs (GitHub Actions) are
  the first candidate for a later version; releases, Discussions and security
  alerts are out. The data layer must allow adding item kinds without a
  rewrite.
- Acting on items inside the app (commenting, assigning, merging, closing).
  Radarix shows and links; GitHub is where work happens.
- GitHub Enterprise Server, Gitea, GitLab. github.com only.
- More than one GitHub account at a time. The data model should not make a
  second account impossible later.
- Mac App Store distribution. iOS.
- An in-app auto-updater (see Distribution).

## Anti-goals (failure even if it "works")

- **Noise.** Items reappearing as "updated" because of the user's own
  activity, or everything showing as "new" right after a repo is added.
- **Burning the rate limit.** Polling must stay far below the limit even with
  dozens of repos.
- **Silent "seen".** Nothing may become "seen" just because it was visible in
  a widget, the menu bar list or a notification banner.
- **Token leaks.** Credentials only ever in the macOS Keychain, never in
  defaults, logs, the shared widget container or crash output.
- Public copy (noix.dev, docs landing, README headline) naming the
  implementation stack.

## Core concepts

**Item:** an issue or a pull request in a watched repo.

**Item state** is local to this Mac; GitHub never learns about it.

| State | Meaning |
|---|---|
| **New** | The item appeared after the repo's baseline and the user has not seen it. |
| **Updated** | The user has seen the item, and it has had activity since (`updated_at` later than the time it was seen). |
| **Seen** | Neither of the above. |

Rules:

- **Baseline.** When a repo is first watched, all its existing items are
  stored as seen. Only items created afterwards become new. (Builder's call
  confirmed by the owner's intent: "new" means new since I started looking.)
  The list still shows all open items, so filters like "unassigned" work on
  the whole backlog, not just on new ones.
- **What counts as activity for "updated":** any change by someone other
  than the signed-in user that moves the item's `updated_at` (comments,
  commits, reviews, review requests, assignees, labels, edits, close, merge,
  reopen, ready for review, ...). There is no per-event-type list to
  maintain. Activity by the signed-in user themselves does not make an item
  updated. Detection: for items whose `updated_at` moved, check the actor of
  the latest change (one cheap lookup); the exact endpoint is the builder's
  call. (Designer's call, settled after review.)
- **Items the user opened themselves** start as seen, in line with the
  own-activity rule. (Designer's call.)
- **Becoming seen:** selecting an item in the main window (like Mail),
  opening it on GitHub from the app, the menu bar list or a notification
  click. Explicit actions: mark item seen/unseen, mark repo seen, mark all
  seen.
- **Closed and merged items** leave the list once they are seen. A new or
  updated item that is closed before the user saw it stays listed (with its
  state shown) until seen.
- **Repo removed from the watch list:** its local state is dropped. Re-adding
  it sets a fresh baseline.

## Features

### Sign-in

- **Default: "Sign in with GitHub"** via the OAuth device flow. The app shows
  a short code and opens github.com/login/device; the user confirms there. An
  OAuth App is registered under the NoiXdev org; its client ID ships in the
  app (the device flow needs no client secret). Scopes: `repo` (needed for
  private repos; OAuth Apps have no read-only variant, the docs must say so
  plainly) and `read:org`.
- **Fallback, under "Advanced": paste a personal access token**, for orgs
  that block third-party OAuth Apps. The settings explain which permissions
  the token needs (classic: `repo`, `read:org`; fine-grained: read access to
  metadata, issues and pull requests on the chosen repos).
- When an org returns no or fewer repos than expected because it restricts
  OAuth Apps, the settings show a hint with a link to grant access.
- Settings (watch list, owner modes, exclusions, per-repo notifications) and
  item state are keyed by the GitHub account id, not by the credential.
  Switching from the OAuth sign-in to a token (or back) for the same account
  keeps everything. (Designer's call, settled after review.)
- **Sign out** removes the credential from the Keychain and the cached API
  data, but keeps settings and seen state for that account, so signing back
  in continues where the user left off. A separate "Reset all data" action
  wipes everything and asks for confirmation.
- **A revoked or expired credential** (401) is an error state, not a
  sign-out: everything is kept, the app shows "Sign in again" in the window,
  the menu bar and settings, and syncing pauses until then.
- The settings show the remaining rate limit and the time of the last sync.

### Choosing repositories (Settings)

- After sign-in, the app lists the user's account and every org they belong
  to.
- Per owner, one mode:
  - **All, except excluded.** New repos in that owner appear automatically.
    The user can exclude individual repos.
  - **Only selected.** The user ticks repos from a searchable list.
  - (An owner can also be off entirely, which is the default for orgs.)
- Archived repos are hidden by default (one toggle shows them). Forks are not
  included by "All" mode; they can be ticked individually.
- Per repo: notifications on/off (default on).

### Main window

- **Two layouts, switchable in Settings** (and the View menu, builder's
  call):
  - **Sidebar (default):** left, owners and their repos with new/updated
    counters, plus "All" at the top as a combined inbox; right, the item list.
  - **Grouped list:** no sidebar, one list grouped by repo, repos without
    matching items hidden.
- **Filters** (toggle chips above the list, combinable): New, Updated,
  Unassigned, Assigned to me, Review requested from me, PRs, Issues. Default:
  New + Updated. A text search over titles is the builder's call.
- **List row:** state badge (new = blue, updated = amber), kind (PR/issue),
  title, repo, relative time, a hint at what changed for updated items (e.g.
  "2 comments").
- **Selecting a row** shows a compact detail pane: title, number, author,
  labels, assignees, requested reviewers, state, the start of the body, an
  "Open on GitHub" button. Selecting marks it seen.
- Refresh button; last sync time visible.

### Bots

- Radarix recognises items opened by bots (Dependabot, Renovate, GitHub
  Actions and any other account GitHub marks as a bot, e.g. user type `Bot`
  or a `[bot]` login suffix).
- Bot items follow the same new/updated/seen rules as any other item.
- **Setting: how bot items are shown** (decided by the owner), one of:
  - **Badge (default):** shown like any other item, with a badge naming the
    bot ("Dependabot").
  - **Grouped:** collected under their own "Bots" group / filter chip, so
    they can be looked at separately.
  - **Hidden:** not listed and not counted in the menu bar or widgets.
- Notifications for bot items are off by default, with one toggle to turn
  them on. (Designer's call.)

### Refresh

- Background sync every 5 minutes by default, configurable (builder picks the
  options, at least 2–30 minutes), plus manual refresh.
- Uses conditional requests (ETag / `If-None-Match`). A `304 Not Modified`
  does not count against the rate limit, so idle repos cost nothing.
- On rate limiting or errors: back off, keep showing the last data, show the
  problem in the window and settings. Never spin.
- Sync runs while the app is in the menu bar, with no window open.

### Menu bar

- Always present while the app runs. Icon (template image, adapts to light
  and dark) with the count of new + updated items across all watched repos.
- Click opens a popover: summary ("5 new · 2 updated"), the newest items
  across repos (builder picks how many, about 8–10), refresh. Clicking an
  item opens it on GitHub and marks it seen. Footer: Mark all seen, Open
  window, Settings.
- Closing the main window keeps the app running in the menu bar. Whether the
  Dock icon is shown only while a window is open is the builder's call.
- Setting: open at login (default off).

### Notifications

- A macOS notification for each **new** item, if notifications are on for
  that repo (default on). Updated items do not notify by default; one global
  toggle can enable that.
- Many new items in one sync are summarised per repo instead of flooding
  (builder picks the threshold).
- Clicking a notification opens the item on GitHub and marks it seen. The
  banner appearing does not.
- The first sync after adding a repo never notifies (baseline).

### Widgets

- Three sizes, as sketched with the owner:
  - **Small:** new count, updated count, the busiest repo.
  - **Medium:** summary line, the 4 newest new/updated items.
  - **Large:** summary, counters per repo, the newest items.
- Each widget can be configured to show all watched repos, one owner, or one
  repo.
- Clicking an item opens Radarix at that item (deep link). The widget itself
  never marks anything seen; the app does, when it shows the item.
- Widgets refresh after each sync.

## Approaches considered

**Sign-in.**
1. OAuth device flow with a NoiXdev OAuth App. Easiest for the user, nothing
   to renew; orgs that restrict OAuth Apps must approve it once.
2. Personal access token. Works everywhere, but the user creates, scopes and
   renews it.
3. GitHub App. Finest permissions, but must be installed into every owner;
   too heavy for a personal tool.

**Chosen by the owner: 1 as the default, 2 as the fallback.**

**Fetching data** (builder's call, made here): REST with conditional
requests per repo, because 304s are free and most repos are idle most of the
time. A GraphQL batch query would need fewer round trips but has no free
"unchanged" answer. The builder may change this if the rate-limit goal still
holds.

**Project structure** (builder's call, made here): the widget needs a real
app extension, so a plain Swift package (as macSCP uses) is not enough. An
Xcode project generated from a checked-in spec file (XcodeGen), with the
logic in a local Swift package that is testable with `swift test`. Plain
hand-edited `.xcodeproj` was rejected because of merge noise; Tuist was
rejected as heavier than needed.

**Main window layout:** the owner reviewed a Mail-like sidebar, a grouped
list and a tile board, and chose sidebar plus grouped list, switchable.

## Technical frame

- macOS 15+, SwiftUI, WidgetKit with App Intents for widget configuration.
- Targets: app, widget extension, shared package `RadarixKit` (GitHub client,
  sync engine, state model, persistence). App and widget share data through
  an App Group container. The token stays in the Keychain and is never
  written to the shared container; the widget reads only the cached snapshot.
- Persistence technology (SwiftData, SQLite, JSON snapshot) is the builder's
  call, as long as the widget can read the state without network access.
- Tests: Swift Testing for `RadarixKit`, especially the state rules (new,
  updated, seen, baseline, own activity) and conditional-request handling,
  against recorded API responses.
- UI languages: English and German (String Catalogs).
- Apple silicon and Intel: builder's call; default to a universal build.

## Distribution and repo

- **Local first.** Development and first builds happen locally, signed with
  the owner's team through Xcode's automatic signing. The GitHub repo and CI
  come later. (Decided by the owner.)
- Then: public repo `NoiXdev/radarix`, MIT license, Conventional Commits.
- **Workflows: the same as macSCP** (CI, release, announce), adapted to an
  Xcode-project build. The signing and notarization secrets and the tap
  token are shared org-level values that become available to the repo once
  it is public. (Decided by the owner.)
- Release: Developer ID signed, notarized, stapled DMG on GitHub Releases,
  then a cask bump in `NoiXdev/homebrew-tap` (`brew install --cask radarix`).

**Owner steps the plan must include (the builder cannot do them):**

- Register the NoiXdev OAuth App with device flow enabled and hand over its
  client ID. Until then, development uses the token sign-in path, which
  needs no registration.
- In the Apple Developer account: App IDs for the app and the widget
  extension and an App Group, needed for the widget to share data. For local
  builds Xcode's automatic signing can create these; the release workflow
  needs them to exist for Developer ID signing.
- No in-app updater in v1. Updates come through Homebrew or GitHub Releases.

## Naming and brand

- **Name: Radarix.** Checked 2026-11-24: free on GitHub (`NoiXdev/radarix`)
  and Homebrew. Two unrelated iPhone apps use the name (speed cameras,
  weather); no conflict in the Mac or developer space. Public copy avoids
  "Git" and "GitHub" in the product name because of their trademark rules.
- **Logo: direction C2**, approved by the owner. Dark navy squircle (as
  macSCP), a faint cyan radar ring, three connected cyan nodes from the
  centre, the newest node in amber. Reference sketches:
  `docs/design/logo-c2.svg` and `docs/design/menubar-c2.svg`. The builder
  produces the final app icon in all sizes and refines the 16 pt menu bar
  glyph so it reads cleanly.
- Brand colours from noix.dev: cyan `#00B8C8`, amber `#F5A524`, ink
  `#0B1524`.

## Publishing (after the first public release)

Order matters because of the rules in those repos:

1. **Docs** in `noix-docs`: `src/content/docs/radarix/` with getting started
   (install, sign in, choose repos), guide (main window, filters, menu bar,
   notifications, widgets, PAT fallback and org access) and reference
   (settings, scopes and permissions, rate limits). Topic in
   `astro.config.mjs`, entry in `src/data/products.ts` (category `mac`).
2. **Project page** on noix.dev, DE and EN (`src/content/projects/{de,en}/radarix.md`)
   with all schema fields, short link, nginx block. Tagline ≤ 70 chars.
3. **Logbuch launch post**, DE and EN, dated to the first public release.
4. Set `docs:` on the project page only once the docs are merged and
   deployed.

Public copy names what the user touches (macOS 15+, GitHub, Homebrew) and
nothing about how it is built.

## Left to the builder

- Persistence technology, sync scheduling mechanism, exact API endpoints.
- Detection of the user's own activity, within the rule above.
- Refresh interval options, popover item count, notification summary
  threshold.
- Dock icon behaviour, View-menu entries, text search.
- Final icon artwork and menu bar glyph refinement.
- Renaming the local working folder from `git-overview` to `radarix`.
