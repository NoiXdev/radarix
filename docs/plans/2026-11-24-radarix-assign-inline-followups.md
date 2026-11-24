# Radarix 1.2: follow-ups

Plan `2026-11-24-radarix-assign-inline.md` is done. This file lists what the reviews deferred and what still needs a person.

## Decisions made during the build

- A duplicate launched at login only quits and opens no window, whereas spec §4 says "reopen". A login launch must not pop up a window. The earlier copy survives.
- When two copies start together, the one launched first stays (by launch date, then by pid).
- Failed assignments show in an alert in the main window. This covers the context menu, and windows that closed in the meantime.

## Before the release (owner, by eye)

- **Assign:**
  - One real assign and unassign, on a repo you can write to.
  - Assign an item you have already seen, then press ⌘R. It must stay seen.
  - On a repo you can only read: the "can't assign" message appears and nothing changes.
  - From the context menu: on an error, the alert appears.
- **Inline description:**
  - Settings → "In the sidebar": the description sits under the details at 360 pt, and long text scrolls.
  - Switch the selection quickly: no wrong description flashes.
- **Background start and Dock:**
  - "Start in the background" is on: no launch opens the main window, and the menu bar item opens it.
  - "Hide from the Dock" is on: the Dock icon disappears only once the main, description and Settings windows are all closed. A minimised window keeps it.
  - Turn the setting off and the icon comes back straight away.
- **One instance:**
  - Start the dev build while 1.2 is running: the running copy comes to the front and the second one quits.
  - Start two copies at the same moment: exactly one stays.
- **Refresh repository:**
  - Works from the sidebar and from the grouped header, with a spinner.
  - It runs once after a full sync that is already in progress.

## Code

- **Tie-break with three or more copies:** with three or more copies and launch dates missing on some, the tie-break is not transitive. Compare by date only when every copy has one, otherwise by pid. Do not treat a missing date as "latest": that breaks the two-copy case.
- **Login renames:** the session login is only set at sign-in. After a rename on GitHub, assigning fails with "can't assign". Refresh the login from `/user` on every sync pass.
- **Journal replay of assignees:** without a version guard, it can overwrite a newer list that a sync brought in. Use the `updated_at` from the write response as the guard.
- **Stale rate limit:** after a successful single-repo refresh, a rate limit that has already expired stays in `syncProblem` until the next full pass.
- **Double `pendingRefresh`:** a second one can be queued. It is harmless, but `stopWork()` only cancels the last one.
- **Missing tests:**
  - A session that ends during a single refresh.
  - A mark on another repo during a single refresh.
  - An assign during a single refresh.
- **Timing in tests:** `settle()` in the tests is timing-based.
- **`FileStore` probe write:** it writes a probe file before the single-instance check. It touches no settings or snapshot.
- **Dock flash:** under "Hide from the Dock" the icon flashes briefly when launched at login.
