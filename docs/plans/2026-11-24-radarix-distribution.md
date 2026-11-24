# Radarix distribution (Plan 3) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship Radarix publicly: update check, signed and notarized releases from tags, the Homebrew cask, user docs on docs.noix.dev, and the project page and launch post on noix.dev.

**Architecture:**
- The update check is kit logic (`RadarixKit/Updates`). It uses the existing `HTTPTransport` seam and an app-owned `UpdateChecker` that the Settings and the popover read.
- Releases follow macSCP: a `scripts/release` shell script drives `xcodebuild archive`/`-exportArchive` (Developer ID), `notarytool`, `stapler` and `hdiutil`. `ci.yml`, `release.yml` and `announce.yml` call it with the org's shared secrets.
- Three other repos receive their own changes on their own branches:
  - `homebrew-tap` (the cask)
  - `noix-docs` (the user guide)
  - `noix.dev` (the project page and the launch post)

**Tech Stack:** Swift 6, SwiftUI, Swift Testing, XcodeGen, GitHub Actions, Homebrew casks, Astro (Starlight for noix-docs).

**Spec:** `docs/specs/2026-11-24-radarix-distribution-design.md` (with `docs/specs/2026-11-24-radarix-design.md`).

## Global Constraints

- **Toolchain:** macOS 15.0 deployment target; Swift 6 strict concurrency.
- **Tests:**
  - Kit tests: `cd Packages/RadarixKit && swift test`. All tests stay green; the count is 234 at plan time.
  - App build: `/opt/homebrew/bin/xcodegen generate -q && xcodebuild -project Radarix.xcodeproj -scheme Radarix -configuration Debug -derivedDataPath DerivedData build`. It must print `** BUILD SUCCEEDED **` and add no new warnings.
- **Language and strings:**
  - Code, comments, commits and internal docs are in English.
  - Every new app UI string goes into `App/Resources/Localizable.xcstrings`, with German.
- **Public copy has no tech stack.** This covers the README, the GitHub description, the cask `desc`, `products.ts`, the noix.dev page and the launch post. Inside the user guide, technical reference may name what is needed.
- **Commits:** Conventional Commits, each ending with the footer `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- **Pushing:** Pushes to `NoiXdev/radarix` happen only where a task says so. The owner allowed them ("den rest kannst du dann machen"). Never force-push. Other repos get branches; merging them is the owner's.
- **Update check:**
  - It sends no token or other credential.
  - It shows nothing when switched off.
  - It never posts a macOS notification.
  - Failures are silent and logged.
- **Release identity:**
  - Repo: `NoiXdev/radarix`.
  - DMG: `Radarix-X.Y.Z.dmg`.
  - Team: `5V8ZCK434F`, with a Developer ID Application certificate from the org secrets.
  - App group: `$(TeamIdentifierPrefix)dev.noix.radarix`.
- **Org secrets**, with the same names as macSCP: `MACOS_CERTIFICATE`, `MACOS_CERTIFICATE_PASSWORD`, `APPLE_API_KEY`, `APPLE_API_KEY_ID`, `APPLE_API_ISSUER`, `TAP_TOKEN`, `DISCORD_WEBHOOK_RELEASE_NOTIFICATION`.
- **Repo secret:** `RADARIX_OAUTH_CLIENT_ID` only (owner, 2026-11-24). The team `5V8ZCK434F` is fixed in `scripts/release` and `Config/ExportOptions.plist`, as macSCP fixes it; the org secrets reach the public repo on their own.
- **Pre-release tags** contain `-`. They publish a GitHub pre-release and skip the tap bump and the announcement.

## Review Focus

1. **A release built without `RADARIX_OAUTH_CLIENT_ID`**: the release must fail before building, not ship a build with sign-in greyed out. Task 3 makes `scripts/release` exit non-zero when the client ID or the team ID is empty; a step checks that.
2. **A tag that is not plain `X.Y.Z`, like `v1.2`, `v1.2.3-rc.1` or `release-1`**:
   - `AppVersion` accepts `1.2` (as `1.2.0`).
   - It rejects suffixes and garbage.
   - The update check ignores a release whose tag does not parse.
   - Tests are in Task 1.
3. **The running app's own version is a pre-release or a dev build (`0.1.0`)**: comparison is numeric, so `1.0.0` counts as newer than `0.1.0`, and `1.10.0` as newer than `1.9.0`. Tests are in Task 1.
4. **GitHub answers 304, 403 (rate limit) or 404 (no release yet), or the Mac is offline**:
   - A 304 keeps the last result.
   - Errors keep the last known result and log.
   - A 404 means "no release": nothing is shown, and it is not an error.
   - Tests are in Task 1.
5. **The user turns the check off while a newer version is shown, or on again**:
   - Off clears the hint at once and stops requests.
   - On checks right away.
   - Tests are in Task 1.

---

### Task 1: Kit: update check logic

**Files:**
- Create: `Packages/RadarixKit/Sources/RadarixKit/Updates/AppVersion.swift`, `Updates/ReleaseSource.swift`, `Updates/UpdateChecker.swift`
- Modify: `Packages/RadarixKit/Sources/RadarixKit/Model/Settings.swift` (add `checkForUpdates`)
- Test: `Packages/RadarixKit/Tests/RadarixKitTests/UpdateCheckTests.swift`, `SchemaEvolutionTests.swift` (one case)

**Interfaces:**
- Consumes: `HTTPTransport` (`send(_:) async throws -> (Data, HTTPURLResponse)`), the test stub `StubTransport` (`enqueue(_ url:status:headers:body:)`, `enqueue(_ url:failure:)`).
- Produces:
  - `public struct AppVersion: Comparable, Sendable, CustomStringConvertible`
    - `init?(_ string: String)` accepts `X`, `X.Y` and `X.Y.Z`, with an optional leading `v`. It rejects anything else, including `-` and `+` suffixes, empty parts and non-digits. Missing parts are 0.
    - `description` is `X.Y.Z`.
  - `public struct LatestRelease: Sendable, Equatable { public let version: AppVersion; public let url: URL }`
  - `public enum ReleaseFetch: Sendable, Equatable { case notModified; case none; case release(LatestRelease?, etag: String?) }`
    - `none` is a 404: there is no release yet.
    - `release(nil, …)` is a 200 whose tag does not parse, or that is a draft or a pre-release.
  - `public protocol ReleaseSource: Sendable { func latest(etag: String?) async throws -> ReleaseFetch }`
  - `public struct GitHubReleaseSource: ReleaseSource`
    - `init(repository: String = "NoiXdev/radarix", transport: HTTPTransport = URLSessionTransport(), baseURL: URL = URL(string: "https://api.github.com")!, userAgent: String)`
    - Requests `GET {baseURL}/repos/{repository}/releases/latest` with the headers `Accept: application/vnd.github+json`, `X-GitHub-Api-Version: 2022-11-28` and `User-Agent: <userAgent>`, plus `If-None-Match` when an ETag is known.
    - It sends no `Authorization` header.
    - It decodes `tag_name`, `html_url`, `draft` and `prerelease`.
    - 304 → `.notModified`; 404 → `.none`; any other non-2xx throws.
  - `@MainActor @Observable public final class UpdateChecker`
    - `init(current: AppVersion, source: ReleaseSource, interval: Duration = .seconds(86_400), sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) })`
    - `public private(set) var available: LatestRelease?` is non-nil only when strictly newer than `current`.
    - `public private(set) var isEnabled = false`
    - `public func setEnabled(_ on: Bool)`:
      - `true` starts a loop that checks at once, then once per `interval`.
      - `false` cancels the loop, sets `available = nil` and makes no request.
      - Calling it with the current value does nothing.
    - `public func checkNow() async` performs one check.
    - The ETag and the last result live in memory only. This is the builder's call from the spec, taken here.
  - `AppSettings.checkForUpdates: Bool = true`, decoded with `decodeIfPresent` (default `true`). `currentSchemaVersion` stays 3, because an added field with a default needs no migration.

- [ ] **Step 1: Write the failing tests** in `UpdateCheckTests.swift`:

```swift
@Test func parsesVersions() {
    #expect(AppVersion("v1.2.3")?.description == "1.2.3")
    #expect(AppVersion("1.2")?.description == "1.2.0")
    #expect(AppVersion("2")?.description == "2.0.0")
    for bad in ["", "v", "1.2.3-rc.1", "1.2.3+4", "1..2", "a.b.c", "release-1", "1.2.3.4"] {
        #expect(AppVersion(bad) == nil, "\(bad)")
    }
}

@Test func comparesNumerically() {
    #expect(AppVersion("1.10.0")! > AppVersion("1.9.0")!)
    #expect(AppVersion("1.0.0")! > AppVersion("0.1.0")!)
    #expect(AppVersion("1.0")! == AppVersion("1.0.0")!)
}

@Test func sourceRequestsLatestWithoutCredentials() async throws
// StubTransport answers 200 with {"tag_name":"v1.1.0","html_url":"https://github.com/NoiXdev/radarix/releases/tag/v1.1.0","draft":false,"prerelease":false}, ETag "abc".
// expect .release(LatestRelease(version: 1.1.0, url: …), etag: "abc");
// the sent request has no Authorization header, the Accept and X-GitHub-Api-Version headers above, and a User-Agent.

@Test func sourceSendsETagAndMaps304And404() async throws
// latest(etag: "abc") sends If-None-Match: "abc"; 304 → .notModified; 404 → .none; 500 throws.

@Test func sourceIgnoresUnparsableOrPrereleaseTags() async throws
// tag "nightly" → .release(nil, etag:); "prerelease": true → .release(nil, etag:).

@Test func checkerShowsOnlyNewerVersions() async
// current 1.0.0: source returns 1.1.0 → available.version == 1.1.0; returns 1.0.0 → nil; returns 0.9.0 → nil.

@Test func checkerKeepsResultOn304AndErrors() async
// after 1.1.0 is shown: .notModified → still 1.1.0; throws URLError(.notConnectedToInternet) → still 1.1.0; .none → nil.

@Test func turningOffClearsAndStopsRequests() async
// setEnabled(true) with a sleep closure that suspends; first check shows 1.1.0;
// setEnabled(false) → available == nil and the source sees no further call
// (scripted source counts calls).

@Test func turningOnChecksAtOnce() async
// setEnabled(true) → the source is called once before any sleep completes.
```

Add to `SchemaEvolutionTests.swift`: `checkForUpdatesDefaultsOn`. It decodes `plan2-settings.json` and a v3 file without the key, and expects `checkForUpdates == true`. An encode/decode round trip keeps `false`.

- [ ] **Step 2: Run** `swift test --filter UpdateCheckTests`. Expected: the build fails, because `AppVersion` is undefined.
- [ ] **Step 3: Implement** the types above. Test the scripted sources with a small actor-backed `ReleaseSource` stub in the test file.
- [ ] **Step 4: Run** `cd Packages/RadarixKit && swift test`. Expected: every test passes, 234 plus the new ones.
- [ ] **Step 5: Commit** `feat(kit): check GitHub for a newer release`

---

### Task 2: App: show available updates

**Files:**
- Modify: `App/AppModel.swift` (own the `UpdateChecker`), `App/Settings/GeneralSettings.swift`, `App/MenuBar/MenuBarPopover.swift`, `App/Resources/Localizable.xcstrings`
- Test: app build; manual check

**Interfaces:**
- Consumes: Task 1's `UpdateChecker`, `GitHubReleaseSource`, `AppVersion` and `AppSettings.checkForUpdates`.
- Decisions:
  - **Owner and wiring:** `AppModel` creates one `UpdateChecker`.
    - `current` is `AppVersion(Bundle.main CFBundleShortVersionString)`. If that does not parse, there is no checker and nothing is shown.
    - `userAgent` is `"Radarix/<version>"`.
    - At launch it calls `setEnabled(settings.checkForUpdates)`.
    - The toggle writes the setting through `controller.updateSettings` and calls `setEnabled`.
  - **Settings → General:** a `Section` with these rows:
    - `Toggle("Check for updates")` → `"Nach Updates suchen"`.
    - While `available` is set:
      - `Text("Version \(v) is available.")` → `"Version %@ ist verfügbar."`
      - `Link("View release", destination: url)` → `"Release ansehen"`
      - `Text("Update with: brew upgrade --cask radarix")` → `"Update mit: brew upgrade --cask radarix"`, with `.textSelection(.enabled)`.
  - **Menu bar popover:** while `available` is set, one line at the bottom: `"Version %@ is available – View release"` → `"Version %@ ist verfügbar – Release ansehen"`. It is a button that opens the release URL.
  - **No other surface:** no notification, no menu bar badge, no widget change.

- [ ] **Step 1: Implement** the wiring and the views.
- [ ] **Step 2: Build.** Expected: it succeeds with no new warnings.
- [ ] **Step 3: Manual check.** Run the Debug app; its version `0.1.0` is lower than any real release.
  - Before the repo has a release, the check gets a 404 and nothing shows.
  - Temporarily point `repository` at `NoiXdev/macSCP` in a local, uncommitted edit, to see the hint in Settings and the popover. Revert the edit.
  - Toggle off: the hint goes away.
- [ ] **Step 4: Commit** `feat: show when a newer Radarix is available`

---

### Task 3: Release script

**Files:**
- Create: `scripts/release` (executable), `Config/ExportOptions.plist`
- Modify: `project.yml` only if archiving needs a setting (for example `SKIP_INSTALL` for the widget). Keep any change minimal and explain it in the commit.
- Test: the local runs in the steps below.

**Interfaces:**
- **Environment inputs:**
  - `RADARIX_VERSION`: if unset, the latest tag without the `v`. If neither exists, exit with an error.
  - `RADARIX_BUILD`: the build number. If unset, `git rev-list --count HEAD`.
  - `RADARIX_OAUTH_CLIENT_ID`: required. If it is empty, exit non-zero with a message before any build.
  - The team is the constant `TEAM_ID=5V8ZCK434F` in the script, not an input.
  - Notary auth works as in macSCP. CI uses `APPLE_API_KEY` (a path), `APPLE_API_KEY_ID` and `APPLE_API_ISSUER`. Locally it uses the keychain profile `radarix-notary`.
- **Flag:** `--unsigned` is a local layout check only; CI never uses it.
  - It archives with `CODE_SIGN_IDENTITY=-`, skips export, notarization and stapling, and copies the `.app` out of the archive.
  - It still builds the DMG, named `dist/Radarix-<version>-unsigned.dmg`.
  - It still requires the client ID. Pass a dummy value locally.
- **Signed path:**
  1. Check that the working tree is clean.
  2. Find the `Developer ID Application: … (5V8ZCK434F)` identity in the keychain with `security find-identity`. Do not hardcode the name.
  3. Run `xcodegen generate`.
  4. Run `xcodebuild archive` with Release, `MARKETING_VERSION`, `CURRENT_PROJECT_VERSION`, `DEVELOPMENT_TEAM=$TEAM_ID`, `CODE_SIGN_STYLE=Manual`, `CODE_SIGN_IDENTITY="Developer ID Application"`, `RADARIX_OAUTH_CLIENT_ID`, `ENABLE_HARDENED_RUNTIME=YES`, and `ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO`.
  5. Run `-exportArchive` with `Config/ExportOptions.plist` (`method` = `developer-id`, `teamID` = `5V8ZCK434F`, `signingStyle` = `manual`).
  6. Zip the app, notarize it and staple it.
  7. Build the DMG with `hdiutil` (volume name `Radarix`, an `Applications` symlink), notarize it and staple it.
  8. Verify with `codesign --verify --deep --strict`, `spctl -a -t exec -vv` on the app, and `stapler validate` on the app and the DMG.
- **Verification:** the script prints the entitlements of the app and of the widget (`codesign -d --entitlements :-`). Each must contain the group `5V8ZCK434F.dev.noix.radarix`.
- **Output:** `dist/Radarix-<version>.dmg`.
- **`.gitignore`:** add `dist/`.

- [ ] **Step 1: Write** `scripts/release` and `Config/ExportOptions.plist`.
- [ ] **Step 2: Check the missing-variable guard.**
  - Run `RADARIX_VERSION=0.0.1 scripts/release --unsigned` with `RADARIX_OAUTH_CLIENT_ID` unset.
  - Expected: a non-zero exit and a message naming `RADARIX_OAUTH_CLIENT_ID`, before any `xcodebuild` output.
- [ ] **Step 3: Check the local layout.**
  - Run `RADARIX_VERSION=0.0.1 RADARIX_OAUTH_CLIENT_ID=dummy scripts/release --unsigned`.
  - Expected:
    - `dist/Radarix-0.0.1-unsigned.dmg` exists.
    - Mounted, it shows `Radarix.app` and `Applications`.
    - The app's Info.plist has `CFBundleShortVersionString` 0.0.1 and `GitHubOAuthClientID` `dummy`.
    - `lipo -archs` on the app binary shows `arm64 x86_64`. If the toolchain refuses universal, record that and fall back to arm64 only, with a note in the script.
    - The widget appex is inside `Contents/PlugIns`.
  - Remove `dist/` afterwards.
- [ ] **Step 4: Run `shellcheck scripts/release`** if it is installed (`brew list shellcheck`); otherwise run `bash -n scripts/release`. Expected: no errors.
- [ ] **Step 5: Commit** `build: add the release script`

---

### Task 4: Workflows

**Files:**
- Create: `.github/workflows/ci.yml`, `.github/workflows/release.yml`, `.github/workflows/announce.yml`
- Test: `actionlint` if installed, otherwise a YAML parse check (`ruby -ryaml -e 'YAML.load_file(ARGV[0])'` per file).

**Interfaces:**
- **Source:** `~/_dev/macSCP/.github/workflows/*.yml`. Keep the same pinned action SHAs, the `macos-latest` runner, the job layout, the comments' intent, the retries and the "finish the bump by hand" step. Adapt the following.
- **`ci.yml`:**
  - Runs on push to `main` and on `pull_request`.
  - Prints `xcodebuild -version` and `swift --version`.
  - Installs XcodeGen with `brew install xcodegen`.
  - Runs `swift test` in `Packages/RadarixKit`.
  - Runs an unsigned Debug app build (`CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO`).
  - If the runner's default Xcode cannot build Swift 6 with the SDK this project needs, select a newer installed Xcode with `sudo xcode-select -s /Applications/Xcode_<n>.app`. Record the measured versions in a comment.
- **`release.yml`:** on a `v*.*.*` tag, plus `workflow_dispatch` with a `tag` input.
  - `changelog` job: generates `CHANGELOG.md` with the throwaway `package.json` trick and the name `radarix`, commits it to `main` with `chore(release): $TAG [skip ci]`, and makes a draft release.
  - `build` job:
    - Checks out the tag.
    - Imports the certificate and prepares the notary key, as in macSCP.
    - Sets `RADARIX_OAUTH_CLIENT_ID: ${{ vars.RADARIX_OAUTH_CLIENT_ID }}`.
    - Runs `RADARIX_VERSION="${TAG#v}" RADARIX_BUILD="${{ github.run_number }}" scripts/release`.
    - Checksums `dist/*.dmg` and publishes it with `prerelease` set for `-` tags.
  - `announce` job: `uses: ./.github/workflows/announce.yml`. It is skipped for `-` tags.
  - `tap` job:
    - Skipped for `-` tags.
    - First checks `gh api repos/NoiXdev/homebrew-tap/contents/Casks/radarix.rb` with `TAP_TOKEN`. A 404 prints a `::notice::` saying the first cask is added by hand, and ends green.
    - Otherwise it dispatches `bump.yml` with `-f kind=cask -f name=radarix`.
- **`announce.yml`:** macSCP's file, unchanged apart from names.

- [ ] **Step 1: Write** the three workflows.
- [ ] **Step 2: Lint.** Expected: no errors.
- [ ] **Step 3: Commit** `ci: add CI, release and announce workflows`

---

### Task 5: Public repo files

**Files:**
- Create: `LICENSE` (MIT, `Copyright (c) 2026 NoiXdev`; check macSCP's LICENSE holder line and use the same holder), `SECURITY.md`, `CHANGELOG.md` (a header only; the release job fills it), `.github/ISSUE_TEMPLATE/{bug_report.yml,feature_request.yml,config.yml}`, `.github/pull_request_template.md`
- Modify: `README.md` (it currently says `git-overview`)
- Test: read-through against the copy rule

**Interfaces:**
- **Sources:** macSCP's files of the same names. Adapt them to Radarix: product name, the facts the app actually has, macOS 15+, and the Discussions/Issues links of `NoiXdev/radarix`.
- **README.** Its sections, in order:
  - one-sentence pitch;
  - what it does (5–7 bullets from the shipped features: several accounts in one list, new and updated PRs and issues, never "seen" without your action, menu bar and notifications, widget, sign in with GitHub or a token, credentials only in the Keychain);
  - Install: `brew install --cask noixdev/tap/radarix`, or the DMG from Releases;
  - Sign in, with token scopes;
  - Updates (the in-app hint and `brew upgrade --cask radarix`);
  - Build from source (XcodeGen, `Config/Local.xcconfig` from the example);
  - License.

  No implementation-stack terms outside "Build from source".
- **SECURITY.md:** report privately via GitHub's "Report a vulnerability". Tokens live only in the macOS Keychain.

- [ ] **Step 1: Write** the files.
- [ ] **Step 2: Check the copy.**
  - Run `grep -niE 'swift|swiftui|xcodegen|widgetkit|xcode' README.md`.
  - Expected: hits only inside "Build from source".
- [ ] **Step 3: Commit** `docs: add the public README, license and repo templates`

---

### Task 6: First push and green CI (controller step)

- [ ] **Step 1:** Confirm that `git status` is clean, that `origin` is `git@github.com:NoiXdev/radarix.git`, and that `NoiXdev/radarix` is still empty.
- [ ] **Step 2:** Run `git push -u origin main`.
- [ ] **Step 3:** Watch the CI run with `gh run watch` on the push run. Expected: green.
  - If it fails, a fix task resumes the Task 4 implementer, typically for the Xcode version.
  - Fixes are new commits. Never force-push.
- [ ] **Step 4:** Set the repo homepage with `gh repo edit NoiXdev/radarix --homepage https://noix.dev/en/projects/radarix`, and add topics: `macos`, `github`, `menu-bar`, `pull-requests`, `issues`.
- [ ] **Step 5:** Turn on private vulnerability reporting, because `SECURITY.md` and the issue chooser send reporters there: `gh api -X PUT repos/NoiXdev/radarix/private-vulnerability-reporting`.
  - Verify with `gh api repos/NoiXdev/radarix/private-vulnerability-reporting`. Expected: `{"enabled":true}`.
  - Record the same gap for macSCP (also `enabled: false`) as a follow-up.

---

### Task 7: Homebrew cask (tap branch)

**Files:**
- Create: `~/_dev/homebrew-tap/Casks/radarix.rb` on the branch `radarix-cask`. Do not push and do not merge.
- Test: `brew style --cask Casks/radarix.rb`, if Homebrew allows it outside a tapped checkout; otherwise `ruby -c`.

**Interfaces:**
- **Style:** `macscp.rb`, with these values:
  - `cask "radarix"`;
  - `version "1.0.0"`;
  - `sha256 :no_check` as a placeholder, replaced in Task 10 before the commit lands;
  - url `https://github.com/NoiXdev/radarix/releases/download/v#{version}/Radarix-#{version}.dmg`;
  - `name "Radarix"`;
  - `desc "Menu bar watcher for new and updated GitHub pull requests and issues"`;
  - `homepage "https://github.com/NoiXdev/radarix"`;
  - `depends_on macos: :sequoia`;
  - `app "Radarix.app"`.
- **`zap trash:`:**
  - `~/Library/Group Containers/5V8ZCK434F.dev.noix.radarix`
  - `~/Library/Preferences/dev.noix.radarix.plist`
  - `~/Library/Saved Application State/dev.noix.radarix.savedState`
  - Include `~/Library/Application Support/Radarix` with a comment: unsigned builds fall back to it.
  - Add a comment that Keychain items are not removed.
- **Measuring the paths:** do it against the rc install in Task 10 before the commit lands.

- [ ] **Step 1:** Create the branch and the file.
- [ ] **Step 2:** Run the style check. Expected: no offenses, or `:no_check` is the only one.
- [ ] **Step 3:** Commit on the branch: `feat: add the radarix cask`. Do not push.

---

### Task 8: User docs (noix-docs branch)

**Files:**
- Create, in `~/_dev/noix-docs` on the branch `docs/radarix` (from `develop`), under `src/content/docs/radarix/`:
  - `getting-started/`: `introduction.md`, `install.md`, `sign-in.md`
  - `guide/`: `accounts.md`, `repositories.md`, `main-window.md`, `menu-bar.md`, `notifications.md`, `widget.md`, `updates.md`
  - `reference/`: `settings.md`, `troubleshooting.md`
- Modify: `astro.config.mjs` (a topic with the groups "Getting started", "User manual" and "Reference"), `src/data/products.ts` (an entry after MacCommander, `category: 'mac'`, `runsOn: 'macOS 15+ · GitHub'`, `repo: 'https://github.com/NoiXdev/radarix'`, `site: \`${SITE}/en/projects/radarix\``, and a tagline equal to Task 9's EN tagline).
- Test: `npm run check` and `npm run build` in noix-docs.

**Interfaces:**
- Follow `noix-docs/CLAUDE.md`: every page has a `title`, a one-sentence `description` and a `sidebar.order`. Facts only, taken from this repo's code and specs: settings names, strings as shown in the app (EN), and the refresh intervals 2/5/10/15/30 min.
- `troubleshooting.md` covers:
  - an org's repos are missing: OAuth app approval or SSO authorization, and a classic token needing `read:org`;
  - a fine-grained token covers one owner only;
  - "sign in again";
  - the widget is empty;
  - adding an account lands on one already added (sign in to the other account on github.com first).

- [ ] **Step 1:** Write the pages and the config entries.
- [ ] **Step 2:** Run `npm run check && npm run build`. Expected: 0 errors, and `dist/llms.txt` lists the radarix pages.
- [ ] **Step 3:** Commit on the branch: `docs(radarix): add the Radarix documentation`. Do not push and do not merge; that is the owner's call. The default branch is `develop`.

---

### Task 9: noix.dev project page and launch post (branch)

**Files:**
- Create, in `~/_dev/noix.dev` on the branch `radarix` (from `main`):
  - `src/content/projects/{de,en}/radarix.md`
  - `src/content/blog/{de,en}/radarix.md`
- Test: the site's check and build commands, from its `package.json` or CLAUDE.md.

**Interfaces:**
- **Frontmatter:** the fields of `projects/en/macscp.md`.
  - `slug: radarix`, `category: mac`, `license: MIT`, `year: 2026`, `repo: https://github.com/NoiXdev/radarix`.
  - `status`: the value macSCP-era pages used before launch, if the schema has one (read the content config). Otherwise `live`, together with Task 10's merge timing.
  - `download: https://github.com/NoiXdev/radarix/releases`
  - `docs: https://docs.noix.dev/radarix/`, set only in Task 10 once the docs are deployed. Leave it out until then if the schema allows that.
  - `platforms` only names what the user touches: `["macOS 15+", "GitHub", "GitHub organizations", "macOS Keychain"]`.
  - Leave out `comparison` unless a fair, factual one exists.
- **Copy:**
  - EN tagline, verbatim: `"New and updated pull requests and issues, without living in GitHub's inbox."`
  - DE tagline: `"Neue und aktualisierte Pull Requests und Issues, ohne im GitHub-Postfach zu wohnen."`
  - Both use the voice of the macSCP pages. There is no tech stack in any of the four files.
- **Launch post:** `kind: launch`, `project: radarix`, `author: team`, `date: 2026-11-24` (or the release day), with tags `["Radarix", "Mac", "New project"]`. Its sections are "What it does" and "Get started" (brew command, sign-in).

- [ ] **Step 1:** Write the four files.
- [ ] **Step 2:** Run the check and the build. Expected: success.
- [ ] **Step 3:** Commit on the branch: `feat: add the Radarix project page and launch post`. Do not push and do not merge.

---

### Task 10: Release (owner gate, then controller)

This task needs the owner's steps from the spec: the OAuth app is registered and `RADARIX_OAUTH_CLIENT_ID` is set as a repo secret. The org secrets reach the public repo on their own.

- [ ] **Step 1 (controller):** Push the tag with `git pull --ff-only && git tag v1.0.0-rc.1 && git push origin v1.0.0-rc.1`, then watch `release.yml`.
  - Expected: a green run, and a GitHub pre-release with `Radarix-1.0.0-rc.1.dmg`.
  - Tap and announce are skipped.
  - Do not run a fix wave on red without reading the logs. Signing or profile errors are the spec's stop point.
- [ ] **Step 2 (owner gate):** Install the rc from its DMG, then check:
  - It opens without a Gatekeeper warning.
  - "Sign in with GitHub" is enabled.
  - Data survives a relaunch.
  - The widget shows data.
  - The update hint does not show (the rc is the latest).

  If the widget is empty or the app cannot reach its group, stop. Next comes the provisioning-profile contingency from the spec, with the owner.
- [ ] **Step 3 (controller):** Measure the real paths for the cask's `zap` on the installed rc with `ls ~/Library/Group\ Containers ~/Library/Preferences | grep -i radarix`, and fix Task 7's branch.
- [ ] **Step 4 (controller):** Push the tag with `git pull --ff-only && git tag v1.0.0 && git push origin v1.0.0`, then watch the run.
  - Expected: green and published.
  - The announcement is posted.
  - The tap job prints the "add the first cask by hand" notice.
- [ ] **Step 5 (controller):** Put the real `sha256` of `Radarix-1.0.0.dmg` (from the run output or `shasum -a 256`) into the tap branch, and amend the branch commit; it was never pushed.
  - Tell the owner that the tap branch, the noix-docs branch and the noix.dev branch are ready, and the merge order: tap, then noix-docs (deployed), then noix.dev with `docs:` set.
  - Merging is the owner's, unless they ask the controller to.
- [ ] **Step 6 (controller):** Update the follow-ups file in this repo:
  - Add the release-specific items the reviews deferred.
  - Mark the done items in `docs/specs/2026-11-24-radarix-design.md` → "Owner steps".
  - Commit `docs: record the 1.0.0 release` and push to `main`.
