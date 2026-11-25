# Keep the GitHub sign-in: implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Radarix stops losing its GitHub sign-in. Debug builds get their own keychain entry, a locked keychain is retried, and a 401 is confirmed before needs-reauth.

**Architecture:**
- The keychain service for debug builds is picked in the app target under `#if DEBUG`.
- `RadarixController` remembers the accounts whose credential could not be read for a temporary reason and retries them at the start of `refresh()`.
- `AccountSession` asks `viewer()` once before it turns a 401 into needs-reauth.

**Tech Stack:**
- Swift 6 (strict concurrency), SwiftUI app, `RadarixKit` Swift package;
- Swift Testing;
- XcodeGen (`project.yml`).

**Spec:** `docs/specs/2026-11-25-radarix-keep-sign-in-design.md`

## Global Constraints

- **Release keychain service stays `dev.noix.radarix.credential`.**
- **Debug keychain service is `dev.noix.radarix.credential.debug`,** chosen only under `#if DEBUG`.
- **Statuses retried:** only `errSecInteractionNotAllowed` (-25308) and `errSecNotAvailable` (-25291). Everything else is not retried.
- **No new UI strings, no UI changes.**
- **Toolchain:**
  - Swift 6 strict concurrency, macOS 15, no new warnings;
  - the build must pass on Xcode 26.6 / Swift 6.3 and on Xcode 27.
- **Code:** no method references as Binding setters.
- **Language:** code, comments and commits are in English.
- **Commits:**
  - Conventional Commits;
  - footer `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`;
  - commit on branch `fix/keep-sign-in` only, never push.
- **Tests:** `cd Packages/RadarixKit && swift test`, all green.

## Review Focus

1. **A revoked token is still caught.** `viewer()` also answers 401, so the account goes to needs-reauth in that same pass, not one pass later.
2. **Offline during the check.** The confirming `viewer()` fails with `.network` → no needs-reauth, `syncProblem` is not cleared to nil, and the next pass retries.
3. **The session ends during the check.** `end()` is called while `viewer()` runs → the generation guard discards the result, and nothing is saved.
4. **A retried credential belongs to an account that was removed or signed in again meanwhile** → no session is replaced, and the retry set is empty.
5. **A denied keychain prompt (-128) or `errSecAuthFailed` (-25293)** → never retried, so the keychain is not read again on later passes.

---

### Task 1: Separate keychain entry for debug builds

**Files:**
- Modify: `Packages/RadarixKit/Sources/RadarixKit/Auth/CredentialStore.swift` (`KeychainCredentialStore`)
- Modify: `App/AppModel.swift:55`
- Test: `Packages/RadarixKit/Tests/RadarixKitTests/KeychainCredentialStoreTests.swift`

**Interfaces:**
- Produces:
  - `public static let defaultService = "dev.noix.radarix.credential"` on `KeychainCredentialStore`;
  - `init(service: String = KeychainCredentialStore.defaultService)`.

- [ ] **Step 1: Write the failing test** `defaultServiceIsTheReleaseEntry`: `#expect(KeychainCredentialStore.defaultService == "dev.noix.radarix.credential")`. This guards the anti-goal that release users stay signed in.
- [ ] **Step 2:** Run `swift test --filter KeychainCredentialStoreTests`. It must FAIL to compile (no `defaultService`).
- [ ] **Step 3: Add `defaultService` and use it as the init default.**
  - In `AppModel`, pass `KeychainCredentialStore(service: Self.credentialService)`.
  - Under `#if DEBUG`, `credentialService` is `"dev.noix.radarix.credential.debug"`.
  - Under `#else`, it is `KeychainCredentialStore.defaultService`.
  - Add a one-line comment on why: debug builds are signed differently, and a shared entry is taken over by whichever build signs in last.
- [ ] **Step 4:** Run `swift test`, which must PASS. Then check that only Debug defines `DEBUG`:

  ```bash
  xcodegen generate
  xcodebuild -scheme Radarix -configuration Release -showBuildSettings | grep SWIFT_ACTIVE_COMPILATION_CONDITIONS
  ```

  Release must not list `DEBUG`. Finally run `xcodebuild -scheme Radarix -configuration Debug build`, which must end in `BUILD SUCCEEDED`.
- [ ] **Step 5:** Commit `fix: give debug builds their own keychain entry`.

### Task 2: Confirm a 401 before needs-reauth

**Files:**
- Modify: `Packages/RadarixKit/Sources/RadarixKit/Controller/AccountSession.swift`. The places that set `auth = .needsReauth` are:
  - `resolvePass` owners `.unauthorized`;
  - the stop branch of `resolvePass` through `finish`;
  - `syncItems` through `finish`;
  - `syncRepo` through `finishRepoSync`.
- Test: `Packages/RadarixKit/Tests/RadarixKitTests/RadarixControllerTests.swift`, plus a `MultiAccountTests` test if one breaks.

**Interfaces:**
- Consumes:
  - `GitHubAPI.viewer() async throws -> Viewer`;
  - `StubGitHubAPI.setViewer(_:)`, which answers every `viewer()` call from then on.
- Produces: `private func rejectionConfirmed() async -> Bool` in `AccountSession`.
  - It runs `api.viewer()` through `cancellable`.
  - It returns true only when that throws `GitHubError.unauthorized`.
  - Every caller checks `generation == self.generation` after it.

**Behavior:**
- **When it runs:** wherever a 401 would set needs-reauth (the owners call failing with `.unauthorized`, or a `SyncReport` with `needsReauth == true` right after the engine returns), first `await rejectionConfirmed()`.
- **Confirmed:** keep today's behavior.
- **Not confirmed:**
  - set `report.needsReauth = false` before `finish` / `finishRepoSync`;
  - for the owners call, return false from `resolvePass` without touching `auth`;
  - the report stays incomplete through the stop it recorded (`isComplete` must not become true: also keep `wasCancelled` / the stop marker so `lastSyncAt` does not move). If `SyncReport` has no other incomplete marker, add `public var unconfirmedRejection = false` and include it in `isComplete`;
  - `syncProblem` stays as it was;
  - `auth` stays `.ok`.

- [ ] **Step 1: Write the failing tests:**
  - `singleUnauthorizedIsConfirmedFirst`:
    - seed, `scriptRepositories("o", .failure(.unauthorized))`, viewer succeeds;
    - after `restoreSessions()`: `auth == .signedIn(login: "me")`, `lastReport?.needsReauth != true`, `lastSyncAt == nil`;
    - the calls contain `.viewer`;
    - the next `refresh()` makes requests again (calls not empty).
  - `confirmedUnauthorizedNeedsReauth`:
    - same setup, plus `setViewer(.failure(.unauthorized))`;
    - expect `auth == .needsReauth(login: "me")`, `lastReport?.needsReauth == true`.
  - `unauthorizedOwnersWhileOfflineStaysSignedIn`:
    - `setOwners(.failure(.unauthorized))` and `setViewer(.failure(.network("offline")))`;
    - `auth` stays signed in;
    - the calls of that refresh are `[.owners, .viewer]`.
  - `repoRefreshUnauthorizedIsConfirmedFirst`: the same check for `refresh(repo:)`.
- [ ] **Step 2: Update the existing tests that expect needs-reauth from a 401.** `unauthorizedDuringSyncMovesToNeedsReauth`, `ownersErrorsFollowTheRules`, `needsReauthClearsOfflineProblem`, `needsReauthSnapshotStatus` and any in `MultiAccountTests`:
  - add `setViewer(.failure(.unauthorized))` where needs-reauth is expected;
  - extend the expected call lists with `.viewer`.

  Run `swift test`. The new tests must FAIL.
- [ ] **Step 3:** Implement as described in Behavior above.
- [ ] **Step 4:** Run `swift test`. Everything must PASS.
- [ ] **Step 5:** Commit `fix: confirm a rejected sign-in before asking to sign in again`.

### Task 3: Retry a credential the keychain could not read

**Files:**
- Modify: `Packages/RadarixKit/Sources/RadarixKit/Auth/CredentialStore.swift` (`KeychainError`)
- Modify: `Packages/RadarixKit/Sources/RadarixKit/Controller/RadarixController.swift`. The touch points are:
  - `restoreSessions`;
  - `refresh()`;
  - `addAccount`;
  - `removeAccount`;
  - `resetAllData`.
- Test: `Packages/RadarixKit/Tests/RadarixKitTests/RadarixControllerTests.swift`
- Test support: `Packages/RadarixKit/Tests/RadarixKitTests/Support/`, a credential store double

**Interfaces:**
- Produces:
  - `public var isTemporary: Bool` on `KeychainError`. It is true for statuses -25308 and -25291 only.
  - `@ObservationIgnored private var unreadableCredentials: Set<AccountID>` on the controller.
  - In test support: `final class ScriptedCredentialStore: CredentialStore, @unchecked Sendable`.
    - It wraps an `InMemoryCredentialStore`.
    - `func failLoads(for: AccountID, with: Error, times: Int)` makes the next `times` loads of that account throw.
    - `loadCount(for:) -> Int` reports how many loads ran.
    - The test `Harness.credentials` becomes this type. It is a drop-in, because it forwards everything else.

**Behavior:**
- **In `restoreSessions`:** when the load throws a `KeychainError` with `isTemporary`, insert the id into `unreadableCredentials`. The needs-reauth session is still created as today.
- **At the start of `refresh()`,** after the existing guards and before `runPass()`, for each id in `unreadableCredentials`:
  - load again;
  - **On a credential:**
    - only if the current session for that id still has `credentialKind == nil`, build a full session (`makeSession` with that session's `account` and `makeAPI(token)`);
    - `adopt(from:)` the old one, then `insert` it;
    - remove the id from the set.
  - **On nil or a non-temporary error:** remove the id. The session stays in needs-reauth.
  - **On a temporary error:** keep the id.
- **Clearing the set:**
  - `addAccount` and `removeAccount` remove their id;
  - `resetAllData` clears the set.

- [ ] **Step 1: Write the failing tests:**
  - `lockedKeychainIsRetriedOnRefresh`:
    - seed, `failLoads(for: me, with: KeychainError(status: -25308), times: 1)`;
    - after `restoreSessions()`: `auth == .needsReauth(login: "me")`;
    - after `refresh()`: `auth == .signedIn(login: "me")`, `credentialKind == .oauth`, and the calls contain `.owners`.
  - `deniedKeychainIsNotRetried`:
    - `failLoads(..., KeychainError(status: -128), times: 1)`;
    - after `restoreSessions()` and two `refresh()`: `loadCount(for: me) == 1`, and still needs-reauth.
  - `stillLockedKeepsRetrying`:
    - `times: 2`;
    - after the first `refresh()`: still needs-reauth;
    - after the second: signed in.
  - `signInDuringRetryWins`:
    - locked once, then `addAccount(token: "pat-new", kind: .personalToken)`;
    - after `refresh()`: `credentialKind == .personalToken`, and the stored credential is still `pat-new`.
  - `keychainErrorTemporaryStatuses`: `isTemporary` is true for -25308 and -25291, and false for -128, -25293 and -25300.
- [ ] **Step 2:** Run `swift test`. The new tests must FAIL.
- [ ] **Step 3:** Implement as described in Behavior above.
- [ ] **Step 4:** Run `swift test`. Everything must PASS.
- [ ] **Step 5:** Commit `fix: retry a sign-in the keychain could not read`.
