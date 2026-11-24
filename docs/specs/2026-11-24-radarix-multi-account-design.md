# Radarix: several GitHub accounts

Status: draft for approval · 2026-11-24
Extends `2026-11-24-radarix-design.md`, which listed "more than one GitHub
account at a time" as a v1 non-goal. This document lifts that non-goal.

## Intent

The owner has a private and a work GitHub account. Radarix should watch
repositories from both at once and show them as **one inbox**: one list,
one count in the menu bar, one widget, notifications from both. Today the
owner would have to sign out and back in to switch, and would never see
both at once.

## Goals

1. Add, list and remove several GitHub accounts in Settings. Each account
   signs in exactly like today (Sign in with GitHub, or a token under
   Advanced).
2. Everything the user sees is merged across accounts: main window ("All"
   and the sidebar), menu bar count and popover, widget, notifications,
   deep links.
3. Accounts fail independently. An expired token, an offline error or an
   exhausted rate limit on one account never stops the others from syncing
   or being shown.
4. A repository visible to more than one account appears **once**. Its
   new/updated/seen state exists once.
5. Existing users keep their account, settings and seen state on upgrade,
   without signing in again.

## Non-goals

- Switching between accounts (one at a time). The owner wants one list.
- Per-account settings for layout, bots, sync interval, notification
  defaults. These stay global.
- Account nicknames ("Private", "Work"). Accounts are labelled by their
  GitHub login. (Designer's call, see Decisions.)
- GitHub Enterprise or other hosts (unchanged from the main spec).

## Anti-goals

- One broken account blanking or freezing the whole app.
- The same issue listed twice, or "seen" in one place and "new" in another.
- The owner's own activity from their *other* account showing up as
  "updated" (e.g. a comment written as the work account on a repo that
  Radarix syncs through the private account).
- Being signed out or losing seen state by the upgrade.
- Tokens anywhere but the Keychain (unchanged).

## Approaches considered

- **A. One session per account, one workspace above them (chosen by the
  owner).** The current `RadarixController` is split into an
  `AccountSession` (credential, API client, `AccountData`, sync engine,
  rate limit, auth and sync-problem state, per account) and a workspace
  that holds the sessions, the global `AppSettings`, the merged views, the
  repo-ownership rule, the widget snapshot and notification planning.
  Failure isolation falls out of the structure; most existing sync and
  seen logic moves into the session unchanged.
- **B. One controller, `account` becomes a dictionary.** Less code moves at
  first, but every method grows a loop and per-account error, rate limit
  and timing have to be separated by hand in each place. The controller is
  already 463 lines. Rejected.

## Design

### Model and storage

- `AccountData` stays one file per account (`accounts/<id>.json`); the
  credential stays one Keychain item per account id. No change there.
- `AppSettings` gets `accountIDs: [AccountID]` (ordered, oldest first) in
  place of `lastAccountID`. Schema version 3. Decoding a v1/v2 file maps
  `lastAccountID` to `[lastAccountID]`; a missing value maps to `[]`.
  Saving writes only v3. A test covers the v2 → v3 path with a fixture
  (in the style of `plan1-settings.json`).
- The account order is the order accounts were added. It decides repo
  ownership (below) and the sidebar order.

### Repo ownership (dedupe)

- Every watched repository is synced by exactly **one** account, its
  *owner session*. Rule: the earliest account in `accountIDs` whose watch
  configuration includes the repo owns it. Repo identity is the GitHub
  repo id (`RepoID`), which is global, so item keys (`repoID` + number)
  stay unique across accounts.
- A later account that would also watch the repo does not sync it. Its
  resolver skips repos owned by an earlier account. Its `AccountData`
  keeps no `RepoState` for them.
- In Settings → Repositories, such a repo shows under the later account as
  checked-but-disabled with "Watched via <login>". (Designer's call: makes
  the rule visible instead of silently ignoring a tick.)
- **Ownership is computed from persisted data, not live health.** Each
  account's last resolved repo set (what its resolver returned at its last
  successful resolution, stored in its `AccountData`) is the input. An
  account that is offline, rate limited or in `needsReauth` keeps its
  repos; they show its last data, marked stale, next to its "sign in
  again" notice. Ownership moves only when the owning account is removed
  or its watch configuration stops including the repo. (Designer's call:
  a network blip must never hand a repo over and reset its seen state.)
- Each sync pass first resolves repo sets in account order (cheap, owner
  and repo listings with ETags), then computes ownership, then syncs items
  for all sessions concurrently. A brand-new account's first pass
  therefore sees the earlier accounts' sets.
- When an account takes over a repo, it starts with a fresh baseline:
  existing open items are not shown as new (the existing baseline rule).
  Seen state from the old account does not carry over. Accepted cost;
  rare.
- A session drops the `RepoState` of repos it does not own at the end of
  each sync, so a re-added account never resumes stale state for a repo
  another account owned in between. Repos it owns keep their state, so a
  single account removed and re-added resumes as today's sign-out/sign-in
  does.
- A re-added account goes to the end of `accountIDs`.
- Mark-seen and mark-unseen go to the session that owns the repo at the
  moment of the mark (the workspace keeps a `RepoID` → session index,
  rebuilt after each ownership computation). A mark on a repo that no
  session owns is dropped. The per-session journal of marks made during a
  running sync stays per session.

### "Me" across accounts

- Wherever the app asks "is this the viewer?", it uses the **set of logins
  of every account in `accountIDs`** (including one in `needsReauth`), not
  only the owning session's login. A removed account no longer counts.
  - own-activity detection in the item state engine and activity probe
    (own comments/edits do not make an item "updated");
  - the filters "Assigned to me" and "Review requested from me";
  - authored-by-me handling for new items.
- `ItemStateEngine`, `ItemFilter` and the probe take `viewers: Set<String>`
  (case-insensitive) instead of `viewer: String`.

### Sessions and syncing

- One sync interval for all accounts (global setting, unchanged). One
  scheduler in the workspace triggers all sessions together; sessions sync
  concurrently. Manual refresh refreshes all.
- Each session keeps its own `syncProblem` (offline, rate limited),
  `needsReauth` state, rate-limit reading and `lastSyncAt`.
- The workspace's "last synced" is the oldest `lastSyncAt` among sessions
  that are not in `needsReauth` (offline and rate-limited sessions count,
  so stale data shows as stale). If every session needs reauth, it is the
  oldest `lastSyncAt` of all.
- A session in `needsReauth` stays in the list and keeps showing its last
  data (marked stale per the existing rules), like a single account does
  today.

### Merged views

- The workspace exposes what the app reads today from the single
  controller, merged across sessions: `repos` (by `RepoID`), `records(in:)`,
  `counts(in:)`, `owners`, `availableRepos` per account, and the
  mark-seen/unseen/all-seen actions (routed to the owning session).
- **Main window sidebar:** "All" on top, then one section per account
  headed by its login, holding that account's owners and the repos it
  owns. An org both accounts belong to can appear in both sections, each
  with only the repos that account owns. With one account the section
  header is omitted (looks as today).
- **Grouped layout:** unchanged; one list grouped by repo.
- **Menu bar:** one count over all accounts. Popover notices are per
  account and name the login when there is more than one ("<login>: sign
  in again").
- **Widget:** one snapshot over all accounts. `WidgetSnapshot.login`
  becomes `logins` (schema bump, tolerant decode: an old single `login`
  maps to a one-element list). The owner scope matches an owner login
  across all accounts (one org widget shows the repos of that org from
  every account). Status:
  - `signedOut` only when no account exists;
  - `needsReauth` only when every account needs it;
  - otherwise `ok`, plus a new `reauthLogins: [String]` field. When it is
    not empty, the widget shows a small "<login>: sign in again" line
    (or "2 accounts need sign-in"), and the stale note follows the merged
    last sync.
- **Menu bar icon:** whatever it shows today for `needsReauth` it shows
  when any account needs reauth; the count still covers all accounts.
- **Notifications:** each session's sync report is planned as today, then
  posted together. The banner names the account only when there is more
  than one. Deep links (`radarix://item/<repoID>/<number>`) need no change.

### Settings

- **Accounts tab** (was "Account"): a list of accounts (login, sign-in
  kind, status: OK / sign in again / offline, rate limit, last sync), each
  with **Remove**. Below: **Add account…**, which runs today's sign-in
  sheet (Sign in with GitHub, token under Advanced).
- **Remove** deletes that account's Keychain credential and drops it from
  `accountIDs`. Its account file stays on disk, so adding it again resumes
  settings and seen state (same as today's sign-out). "Reset all data"
  stays one action for everything.
- Adding an account that is already in the list updates its credential
  (today's re-sign-in path), no duplicate.
- Sign in with GitHub picks up whoever is signed in on github.com in the
  browser. The add sheet says so in one line ("Make sure the right account
  is signed in on github.com").
- **Repositories tab:** grouped by account, then owner, as today within
  each account.

### Upgrade

- First launch of the new version: v2 settings with `lastAccountID = X`
  become `accountIDs = [X]`, the session for X restores from the Keychain
  as today. Nothing else changes for a single-account user.

## Constraints

- Swift 6 strict concurrency, SwiftUI, kit logic in `RadarixKit` with
  Swift Testing (current: 189 tests). New logic comes with tests.
- Never-silent-"seen" rule unchanged.
- Code and docs in English; UI strings via the string catalog with German.
- Credentials only in the Keychain.

## Decisions (designer's calls, open to the owner)

1. Accounts are labelled by login only, no nicknames.
2. Ownership by account order (oldest first), shown in Settings as
   "Watched via <login>".
3. Ownership is persisted; an unhealthy account keeps its repos (stale)
   instead of handing them over.
4. The logins of every account in the list count as "me".
5. One global sync interval, all accounts synced together.
6. Remove keeps the account file (resume on re-add); a re-added account
   goes last.
7. One org widget covers that org across all accounts.

## Left to the builder

- Exact type names and file split of workspace vs session.
- How the workspace notifies the app (observation vs callbacks).
- Popover and settings layout details within the existing style.
- Whether `RadarixControllerTests` move to the session as they are (the
  session keeps a controller-like single-account API) or are rewritten.
