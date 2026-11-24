# Radarix menu bar, notifications and widget: follow-ups

Plan 2 (`2026-11-24-radarix-menubar-widget.md`) is merged into `main`. This file lists what the task reviews and the final whole-branch review deferred. Items fixed before the merge are left out. The Plan 1 list (`2026-11-24-radarix-core-followups.md`) still applies. Its "Do first" and "Before OAuth ships" sections are done. The restricted-org hint is a footnote link on every OAuth organization.

## Do next

- **Move `MainNavigation` into the kit and test it.** It is the only automated cover for "never silent seen" on deep links. Test unknown item, closed-and-seen item, unwatched repo, and the grouped vs sidebar layouts.
- **Global notification cap.** The summary is per repo only. After a long absence, 20 repos with 3 new items each still give 60 banners. Add one overall summary above N notifications per sync.
- **Single window on a link launch.** It relies on the link's window appearing before the menu bar label claims one: 35 of 35 observed, but not guaranteed. Revisit if the owner ever sees two windows after a widget or notification click.

## Widget

- Unsigned builds cannot share the group container with the widget, so the widget stays empty until the app is team-signed (`Config/Local.xcconfig`). The app itself persists through the `FileStore` fallback (5244e8c).
- `CountTile` in accented or desaturated rendering (desktop not focused). Check white-on-blue and ink-on-amber, and use `widgetRenderingMode` if they wash out. White on `#2F7CF6` is about 4.1:1.
- The duplicated "Nothing new." `Text` in `SmallOverview` and `NothingNew`.
- With a sync interval over 1 h, a running app can still show the stale note after 2 h.

## Notifications

- `UNUserNotificationCenter.add` errors are dropped silently. Log them.
- An item-notification click marks the item's current `updatedAt` as seen, not the announced version. Add a comment.
- Planning and posting still happen when authorization is denied (harmless no-ops).
- Tests:
  - `botsNotifyWhenEnabled` asserts only the count;
  - filtered bots should not count toward the threshold;
  - the case-insensitive repo name tie;
  - the same key twice within one list.

## Menu bar and app

- The popover's entries guard drops records whose repo is missing from `account.repos`.
- An expired rate-limit notice leaves an empty strip until the next sync.
- Identical `one`/`other` plural cases.
- A link consumed while `account.repos` is still empty (cached account before the first sync) is lost.
- `showsLayout` duplicates the `content` branch condition in `MainWindow`.
- The open-at-login error text is not cleared when the status refresh shows it fine again. `SMAppService` errors show the generic message.
- With several main windows open, any of them may consume a navigation.
- The glyph ring at 50 % alpha may be faint on light menu bars. At @1x the C2 diagonal still reads faintly as a slash.

## Kit

- The snapshot selection duplicates the `ItemFilter.counts` predicate. The parity test mitigates this; a shared helper would remove it.
- The parity test does not exercise the 6-item cap. `Summary` has no public init.
- `signIn` writes a transient snapshot of the previous session before `begin()`.
- An extra snapshot write happens before `requestRefresh`. It is deduplicated for reloads now.
- `radarix://open/` with a trailing slash is rejected.
- Device flow:
  - the `ErrorBody` decode is duplicated in `start()`;
  - `DeviceFlowError` case formatting;
  - `waitForToken` ignores the error code on non-200;
  - the non-200 unknown-code path in `start()` is untested.
- Tests: owners-401 clearing `syncProblem`; the raw JSON `schemaVersion`; individual `WatchConfig`/`Item` defaults.
- `RadarixController.swift` is past 420 lines. An optional `+Sync` / `+Snapshot` extension split.

## Several accounts (Plan 3a)

- A launch deep link is handled once the first account is restored. A link to a repo of a later account that is still restoring lands on "All".
- `controller.repos` is rebuilt several times per render (negligible today).
- Adding an account awaits a full pass of every account, so the add sheet stays open that long, and Cancel does not cancel a token sign-in: the account is still added. `addAccount` could `requestRefresh()` and return; the token task could then be cancelled safely until the credential is saved. Tests would await `pendingRefresh`.
- Device and add sheets:
  - closing the device sheet after accept leaves the add sheet open, and a later cancelled flow closes it unexpectedly;
  - Cancel in the add sheet does not cancel an in-flight token sign-in (see above);
  - a launch `restoreSessions` during a signed-out device flow flips `accepted` early.
- "Sign in again" opens the generic add sheet. If github.com has the other login signed in, the device flow re-signs that account or adds a third, and nothing says so. Pass the expected login into the sheet ("Sign in as <login>") and note a different result.
- Remove has no confirmation. For repos another account also watches, that account takes over with a fresh baseline, and the re-added account goes last for good. Confirm when the account owns repos another account watches, or at least correct the "adding it again resumes it" comment.
- The Repositories tab says "No accounts or organizations found" for an account that has not fetched its owners this launch (in reauth, or offline at launch), and its watch config cannot be edited. Fall back to the owners in `account.watch.owners` and `account.available`, or say that the account needs to sign in again.
- Turning an owner Off and On again within one launch can leave its repos unsynced: the repo-list ETag stays, the list answers 304, and without a previous list the owner is unknown until the ETag changes or the app restarts. Refetch unconditionally on `.notModified` without a previous list, or forget the list URL's ETag when an owner goes Off. (Predates Plan 3a.)
- A healthy account has no status line in the Accounts tab (no "OK" string). Accepted: the spec only needs the problem states visible.
- `SyncStop` has a public `Error` conformance (harmless).
- `rateLimit()` is not cancellable; an extra account save happens mid-pass.
- `suppressSnapshot` is reset without `defer` (nothing in that span throws).
- A two-account restore whose account file is missing may write a partial snapshot briefly (rare).
- The new widget string keys are unsorted in the catalog (Xcode re-sorts on the next edit).
- Test gaps:
  - settings precedence when both `lastAccountID` and `accountIDs` are present (a v3 file never carries `lastAccountID`);
  - multi-login `GitHubClient`/`SyncEngine` activity;
  - `resolveStopsOnReauth` does not assert that the loop stops;
  - no direct `AccountSession` tests (covered through the controller);
  - a two-account snapshot `syncedAt` carry;
  - the duplicated resolve → sync test glue;
  - the duplicated `TestClock` helper.

## Manual checks still open (owner, with team signing)

1. Sign in with a token, set NoiXdev to All, relaunch: the data is restored.
2. Main window, menu bar label and popover in light and dark.
3. Notifications:
   - the permission prompt;
   - a real item notification and its click: opens on GitHub and marks it seen;
   - a summary click: opens the repo and marks nothing.
4. Widget in all sizes and scopes. Quit Radarix and check that the stale note appears after 2 h.
5. With Radarix not running, click the widget and a notification: exactly one window opens.
6. Turn on open at login, log out and in: no window, menu bar only. A Dock click then opens the window.
7. Console: no WidgetKit throttling messages during a normal day.

Several accounts (Plan 3a):

8. Add a second account by device flow and by token. Each time, the right account must be signed in on github.com.
9. With two accounts, check:
   - the sidebar sections;
   - the menu bar popover;
   - the Accounts tab, including Sign in again and Remove;
   - the Repositories tab per-account sections, "Watched via", and the global search in both modes, including the no-match line;
   - that a repo shared by both accounts shows and notifies once;
   - that removing one account clears only its notifications.
10. The widget reauth line, for one and for two accounts.
11. An account whose credential is missing at launch: delete one account's Keychain item (or deny access when asked) and relaunch. The account keeps its sidebar section and its repos (stale), the "sign in again" banner, the menu bar `!` after the count, the widget reauth line and its Accounts row without "Signed in with". Sign in again and Remove both work.
