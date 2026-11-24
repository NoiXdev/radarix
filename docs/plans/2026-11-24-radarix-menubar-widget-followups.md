# Radarix menu bar, notifications and widget: follow-ups

Plan 2 (`2026-11-24-radarix-menubar-widget.md`) is merged into `main`. This file lists what the task reviews and the final whole-branch review deferred. Items fixed before the merge are left out. The Plan 1 list (`2026-11-24-radarix-core-followups.md`) still applies. Its "Do first" and "Before OAuth ships" sections are done. The restricted-org hint is a footnote link on every OAuth organization.

## Open decision (owner)

- **Unsigned builds cannot persist anything.** macOS denies an ad-hoc signed app access to the group container `~/Library/Group Containers/dev.noix.radarix`, so settings, the account file and the widget snapshot fail to save. This has been true since Plan 1. Two options:
  - team signing via `Config/Local.xcconfig` (needed for the widget anyway);
  - a `FileStore` fallback to `~/Library/Application Support/Radarix` when the group directory is not writable. The app would work, but the widget would stay empty.

## Do next

- **Move `MainNavigation` into the kit and test it.** It is the only automated cover for "never silent seen" on deep links. Test unknown item, closed-and-seen item, unwatched repo, and the grouped vs sidebar layouts.
- **Global notification cap.** The summary is per repo only. After a long absence, 20 repos with 3 new items each still give 60 banners. Add one overall summary above N notifications per sync.
- **Single window on a link launch.** It relies on the link's window appearing before the menu bar label claims one: 35 of 35 observed, but not guaranteed. Revisit if the owner ever sees two windows after a widget or notification click.

## Widget

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
