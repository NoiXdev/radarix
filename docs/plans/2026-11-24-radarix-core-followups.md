# Radarix core: follow-ups for Plan 2

Plan 1 (`2026-11-24-radarix-core.md`) is merged into `master`. This file lists what the task reviews and the final whole-branch review deferred. Items fixed before the merge are left out.

## Do first in Plan 2

- **Persisted schema evolution.** Synthesized `Decodable` rejects files that lack a newly added key. Before Plan 2 adds any persisted field, add `decodeIfPresent` defaults and a schema version to `AppSettings`, `AccountData`, `RepoState`, `ItemRecord` and `Item`. Without this, the first new field resets `settings.json` (loses `lastAccountID`, signs the user out) and makes the account file unreadable (sign-in dead end until Reset).
- **`lastSyncAt` while offline.** When `owners()` fails offline and known owners are reused, a completed engine run still sets `lastSyncAt`, so "Synced just now" can appear beside the offline banner. Fix: only set it when the owners call succeeded in that pass.
- **`AttentionCounts` public init.** Needed by the widget target and previews outside the module.

## Before OAuth ships (real client id)

- `DeviceFlow.start()` lets a raw `DecodingError` escape on a 200 with `{"error": …}`. Map `device_flow_disabled` and `incorrect_client_credentials` to `DeviceFlowError`. `waitForToken`'s `try? decode` turns a malformed 200 into `.http(200)`.
- OAuth-restricted orgs answer 200 with only public repos, so no hint appears. Add a per-org "Missing repositories? Grant access" link for OAuth credentials.
- "Reset all data" can leave an earlier account's Keychain credential (only reachable via "Sign in again" from needsReauth). Add `CredentialStore.deleteAll()`.
- Signing: switching from ad-hoc to team signing changes `RadarixAppGroup` from `dev.noix.radarix` to `<TEAM>.dev.noix.radarix`, so the store directory moves and earlier data is not found.

## Sync and state

- The activity probe treats "nothing explains the move" as the viewer's own activity: body or comment edits by others, commits with an older committer date, and others' entries on the second-to-last timeline page are missed. Matches the plan's rule; revisit.
- Probe fan-out: a bulk change to N seen items costs N–2N uncached timeline calls. Consider a per-sync cap that falls back to `otherActivity: nil`.
- Pre-existing items get `commentsAtSeen: 0`, so a reopened old issue shows "40 new comments". Use `item.commentCount`.
- Deleted or transferred items stay listed; closed seen records accumulate. Add periodic reconciliation.
- An interval change cancels an in-flight scheduled sync (nothing lost; run refresh outside the loop's cancellation).
- `needsReauth` after an `.offline` owners pass leaves `syncProblem` at `.offline` (cosmetic).
- Corrupt account file is a sign-in dead end until Reset; corrupt `settings.json` silently falls back to defaults (known v1 limitations). Save failures are only logged (consider `lastSaveError`).
- Smaller: cancelled `owners()` treated as an error; cancelled `pendingRefresh` body still runs; a repo unwatched mid-sync stays visible until the follow-up sync; owner comparison at `SyncEngine.swift:66` is case-sensitive; empty catch-all at `SyncEngine.swift:82` (add `assertionFailure`); `forgetConditionalState` misses the bare `/repos/{o}/{n}` URL; Link parsing splits on ","; out-of-order responses may overwrite `latestRateLimit`; `slow_down` with a smaller interval can lower the polling interval; Keychain delete-then-add is not atomic; resolver doesn't dedupe repos across owner keys.

## App UI

- No "Reset all data" while signed out.
- White on blue `#2F7CF6` badge is about 4.1:1 (below AA for small text). Revisit with the icon and visual pass.
- Switching All ↔ Only selected silently drops the exclusion or selection set.
- Non-lazy `Form` in the Repositories tab may be slow for orgs with hundreds of repos.
- Sidebar selection of a repo that disappeared is not reset to "All".
- Rate-limit banner can linger up to a minute; empty "Synced" toolbar item while `lastSyncAt` is nil; `FilterSet` JSON decoded on every read.
- `MainWindow.swift` mixes data types and banners (split into `Banners.swift` / `ItemModels.swift`); `PreviewSamples.swift` is not under `#if DEBUG`; `RadarixController.swift` is ~360 lines (optional `+Sync` extension).
- German: "Reset um %@" reads clipped ("zurückgesetzt um %@").
- Menu commands Refresh and Mark all as seen are always enabled (the controller guards them).

## Tests to add

- Scheduler loop (no test today).
- `seenStaysSeenOnOwnActivity` should assert `commentsAtSeen` advances; `.updated` stays `.updated` on further moves; multi-item baseline.
- End-to-end two-page `items(.openForBaseline)` (paging is covered transitively via `followsLinkNextAcrossPages`).
- Timeline entry with a timestamp but no login; excerpt with whitespace and emoji.

## Manual checks still open (owner)

Sign in with a token, set NoiXdev to All, relaunch (data restored without a new sign-in); main window and Settings in light and dark; both layouts, filters, ⌘R and ⇧⌘K.
