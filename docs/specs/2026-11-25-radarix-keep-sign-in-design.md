# Radarix: keep the GitHub sign-in. Design (short)

Status: the owner approved all three fixes ("Yes, all three"), 2026-11-25.

## Intent

The owner keeps getting signed out: Radarix suddenly asks to sign in to
GitHub again. They want the sign-in to stay.

## What causes it (evidence)

- The token is a generic password in the login keychain (service
  `dev.noix.radarix.credential`). Its access list trusts only the app that
  wrote it. On 2026-11-25 that was `/Applications/Radarix.app`, signed with
  Developer ID (team 5V8ZCK434F), with partition `teamid:5V8ZCK434F`.
- Debug builds are signed ad hoc: no team, and a new signature on every
  build. A debug build can't read the release build's entry, so it shows
  "sign in again". Signing in there makes `save()` delete the entry and write
  it again for the debug build. Then the release build can't read it. The
  two builds keep taking the sign-in away from each other.
- Two things make it worse:
  - **A keychain read error counts as "no credential" for the whole run.**
    The read fails, for example, when the keychain is locked.
  - **A single 401 puts the account in needs-reauth.** It stays there until
    the next launch.

## Goals

1. **Debug builds use their own keychain entry.** The service is
   `dev.noix.radarix.credential.debug`, chosen only under `#if DEBUG` in the
   app. Release builds keep `dev.noix.radarix.credential`. A debug build
   never reads, writes or deletes the release entry.
2. **A temporarily unreadable credential is tried again.**
   - **Which errors:** `restoreSessions` remembers the accounts whose
     credential load failed with `errSecInteractionNotAllowed` (-25308) or
     `errSecNotAvailable` (-25291).
   - **Until then:** such an account keeps its needs-reauth session, so the
     UI is unchanged for now.
   - **When it is tried again:** at the start of every `refresh()`, the load
     runs again. On success the account gets a full session, which takes
     over the old one (`adopt(from:)`), and it syncs in that pass.
   - **Other results:** "not found" or any other error ends the retrying,
     and the account stays in needs-reauth. A denied prompt is never retried,
     so the user is not asked again every pass.
   - **Signing in or removing:** either one drops the account from the retry
     set. Resetting all data clears the set.
3. **A 401 is confirmed before needs-reauth.**
   - When the owners call, a repo list or an item sync gets a 401, the
     session asks `viewer()` (`GET /user`) once.
   - Only a 401 there sets needs-reauth.
   - **Any other answer** (success, offline, anything else): the pass ends
     as not complete, without needs-reauth and without a sign-in notice.
     The next scheduled pass tries again.

## Non-goals

- The data-protection keychain or keychain access groups. They need a
  Developer ID provisioning profile, and goal 1 removes the need.
- Separate data folders or bundle ids for debug builds.
- New UI or new strings.

## Anti-goals

The design has failed if:

- a release build reads, writes or deletes a different keychain entry than
  before (that would sign out every existing user);
- a keychain prompt the user denied comes back on every pass;
- a token that GitHub really revoked stays in "ok" for more than one pass.

## Approaches

1. **Our choice:** a separate debug service, retrying, and confirming the 401.
   - **Small, with no migration.** The release entry is untouched.
2. **The data-protection keychain with a team access group.**
   - No per-app access list, so there are no prompts.
   - **Against it:** it needs a provisioning profile and a migration of the
     existing entries, and debug builds would still need a separate group.
3. **A different bundle id for debug builds.**
   - That would separate the keychain and the data too.
   - **Against it:** it touches the app group, the widget, the URL scheme
     and the single-instance check. That is too much for this fix.

## Left to the builder

- Helper names.
- Where the "temporary" classification lives. A suggestion is
  `KeychainError.isTemporary`.
