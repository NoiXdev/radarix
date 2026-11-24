# Radarix distribution (Plan 3): design

Status: approved approaches (owner, 2026-11-24); this document awaits owner approval.
Builds on `2026-11-24-radarix-design.md` (section "Distribution and repo") and
`2026-11-24-radarix-multi-account-design.md`.

## Intent

Radarix goes public the way the other NoiX Mac tools did: anyone can install it with
`brew install --cask radarix` or a signed DMG, sign in with GitHub, and learn about new
versions without an auto-updater. The owner wants it to feel like macSCP and MacCommander
from the outside: same release flow, same tap, same docs site, same kind of project page
and launch post.

## Goals

1. **Public repo** `NoiXdev/radarix` (MIT) with the repo files the siblings have: README
   (public copy, no tech stack), LICENSE, SECURITY.md, CHANGELOG.md, issue templates.
   The local folder stays `git-overview`; the README title and text become Radarix.
2. **CI** on pushes to `main` and on pull requests: kit tests and an unsigned app build.
3. **Release** on a pushed tag `vX.Y.Z` (and `workflow_dispatch` with an existing tag):
   changelog from Conventional Commits committed back to `main`, a Developer ID signed,
   notarized and stapled `Radarix-X.Y.Z.dmg` on GitHub Releases, then the Homebrew cask
   bump and the Discord announcement. First release: **1.0.0**.
4. **Sign in with GitHub in release builds.** The release build gets the NoiXdev OAuth
   App's client ID from CI, so the device flow is available. (Owner decision: A.)
5. **Update check** (owner confirmed the proposal as sketched, 2026-11-24), below.
6. **Homebrew cask** `radarix` in `NoiXdev/homebrew-tap`.
7. **User docs** in `noix-docs` under `src/content/docs/radarix/`, following that repo's
   "New product" checklist.
8. **noix.dev**: a project page and a launch post, each in DE and EN.

## Non-goals

- An auto-updater or in-app download (Sparkle or similar). The update check only informs.
- Mac App Store distribution.
- Platforms other than macOS 15+.
- Repos where the user is only a collaborator on another person's account, or an outside
  collaborator of an org (noted as a possible later feature, not part of this plan).

## Anti-goals (a release that technically ships but fails)

- A release build without the OAuth client ID, so "Sign in with GitHub" is greyed out.
  The release job must fail when the client ID is missing.
- A DMG that is not notarized, or an app whose widget cannot reach the shared App Group
  because the widget extension was signed differently from the app.
- An update check that nags: no macOS notification, no error shown when offline or when
  GitHub fails, no check at all when switched off.
- Public copy (README, products.ts, project page, launch post, cask `desc`) that names the
  implementation stack. Inside the user guide, technical reference may name what is needed.

## Constraints

- Build: XcodeGen project (`project.yml`); `*.xcodeproj` is git-ignored, so CI installs
  XcodeGen and generates the project. Targets `Radarix` (`dev.noix.radarix`) and the
  widget extension (`dev.noix.radarix.widget`), macOS 15.0, Swift 6 strict concurrency.
  The kit package `Packages/RadarixKit` is tested with `swift test`.
- Version today: `MARKETING_VERSION = 0.1.0`, `CURRENT_PROJECT_VERSION = 1` in
  `Config/Base.xcconfig`. The release sets the marketing version from the tag.
- Signing: App Group `$(TeamIdentifierPrefix)dev.noix.radarix` is team-prefixed, so
  Developer ID signing needs no provisioning profile. The release build needs the team id
  (for `TeamIdentifierPrefix`), fixed as `5V8ZCK434F` in the script as in macSCP, and the
  Developer ID Application identity.
- Shared org-level secrets, available to the repo once it is public (same names as
  macSCP): `MACOS_CERTIFICATE`, `MACOS_CERTIFICATE_PASSWORD`, `APPLE_API_KEY`,
  `APPLE_API_KEY_ID`, `APPLE_API_ISSUER`, `TAP_TOKEN`,
  `DISCORD_WEBHOOK_RELEASE_NOTIFICATION`. New for Radarix: only the OAuth client ID, as the
  repository **variable** `RADARIX_OAUTH_CLIENT_ID` (not a secret; a client ID is public).
  The org secrets reach the public repo without further setup (owner, 2026-11-24).
- macSCP's CI lesson applies: the hosted runner's Xcode/Swift can be older than the local
  toolchain, and strict-concurrency diagnostics can differ. Workflows print
  `xcodebuild -version` and `swift --version`, and pick an Xcode the build accepts.
- Conventional Commits; the repos' CI gates enforce them. Default branch `main`.
- Credentials stay in the Keychain only; the update check sends no token.

## Approaches

**Release build.** (A) A `scripts/release` shell script, macSCP-style but driving
`xcodebuild archive` + `-exportArchive` (method `developer-id`), `notarytool`, `stapler`
and `hdiutil`; the workflows call it and it also runs locally. (B) Fastlane: less own
script, but a new Ruby dependency no sibling uses. (C) Xcode Cloud: does not fit the
org secrets and the tap flow. **Owner picked A.**

**Update check request.** (A) Unauthenticated `GET
https://api.github.com/repos/NoiXdev/radarix/releases/latest` with an ETag; 60 requests
per hour per IP is far more than one a day, and it works signed out. (B) With an
account's token: no gain, and it spends the rate limit the syncs need. **Owner picked A.**

## The update check

- When: once shortly after launch, then every 24 hours while the app runs. A check also
  runs when the switch is turned back on.
- What: `releases/latest` (GitHub excludes drafts and pre-releases there). The tag
  `vX.Y.Z` is compared as a semantic version with the app's `CFBundleShortVersionString`.
  Only a strictly newer version counts.
- Shown when newer:
  - Settings → General, under a toggle **"Check for updates"** (`"Nach Updates suchen"`,
    default on): **"Version %@ is available."** (`"Version %@ ist verfügbar."`), a link
    **"View release"** (`"Release ansehen"`) to the release's `html_url`, and the line
    **"Update with: brew upgrade --cask radarix"** (`"Update mit: brew upgrade --cask radarix"`).
  - The menu bar popover: one line at the bottom, **"Version %@ is available – View
    release"**, only while a newer version is known.
- Not shown: no macOS notification, no badge on the menu bar icon, no widget change.
- Failure (offline, HTTP error, rate limit, unparsable tag): silent, logged, retried at
  the next scheduled check. A known newer version stays shown until a check proves
  otherwise or the user updates.
- Off: no request is made; the hint disappears.
- Persisted: the toggle in `AppSettings` (tolerant decode, default on). The ETag and the
  last known latest version may be persisted or kept in memory (builder's call); either
  way a 304 keeps the last known result.
- Logic (version compare, response parsing, scheduling decision) lives in `RadarixKit`
  with tests; the app shows the result.

## Release pipeline

- `ci.yml`: on push to `main` and PRs; generate the project, `swift test` in the kit,
  unsigned Debug build of the app (widget embedded).
- `release.yml`: jobs as in macSCP (changelog → build/sign/notarize → publish release →
  announce + tap bump). The build job fails early if the OAuth client ID variable is
  empty. It checks out the tagged source. Pre-release tags (`-`) are marked
  as pre-releases. The DMG's SHA-256 goes to the tap bump.
- `announce.yml`: the org's shared Discord action, callable and dispatchable, as macSCP.
- `scripts/release`: generates the project with the version from the tag, archives
  Release with Developer ID (app and widget signed with hardened runtime and the same
  team), exports, builds `Radarix-X.Y.Z.dmg` with an Applications link, notarizes,
  staples app and DMG, verifies (`spctl`, `codesign --verify --deep --strict`,
  `stapler validate`). Universal (arm64 + x86_64) like macSCP unless the toolchain makes
  that impossible (builder verifies, records the result).
- Build number: derived deterministically per release (builder's call, documented).

## Homebrew cask

`Casks/radarix.rb` in `NoiXdev/homebrew-tap`, in the style of `macscp.rb`: `version`,
`sha256`, url `https://github.com/NoiXdev/radarix/releases/download/v#{version}/Radarix-#{version}.dmg`,
`name "Radarix"`, a stack-free `desc`, `homepage`, `depends_on macos: :sequoia`,
`app "Radarix.app"`, and a `zap` whose paths are measured against the installed app
(at least the group container `~/Library/Group Containers/<TEAMID>.dev.noix.radarix`,
`~/Library/Application Support/Radarix` for unsigned fallbacks only if a release can
ever write there, preferences and saved state). A comment notes that Keychain items are
not removed. The first `version`/`sha256` come from the 1.0.0 release; the cask lands in
the tap with or right after it.

## User docs (noix-docs)

New product per `noix-docs/CLAUDE.md`: `src/content/docs/radarix/` with
`getting-started/` (introduction, install, sign in), `guide/` (accounts, repositories,
main window, menu bar, notifications, widget, updates) and `reference/` (settings,
troubleshooting: org access, token scopes, fine-grained tokens are limited to one owner,
SSO authorization). A topic in `astro.config.mjs`, an entry in `src/data/products.ts`
(tagline copied from the EN project page). Facts only, from this repo. Build and check
must pass. On noix.dev, `docs:` is set only after the docs are merged and deployed.

## noix.dev

- `src/content/projects/{de,en}/radarix.md` with the macSCP frontmatter fields (slug,
  title, tagline, summary, category `mac`, audience, status, repo, docs, download,
  platforms, license MIT, year, order, featured, updated, comparison if a fair one
  exists). `status: live` and `download` only once 1.0.0 is published.
- `src/content/blog/{de,en}/radarix.md`, `kind: launch`, `project: radarix`, in the
  voice of the macSCP launch post. No tech stack in either.

## Owner steps (the builder cannot do them)

1. Register the NoiXdev OAuth App with device flow enabled; provide the client ID.
2. ~~Create the public repo~~ (done by the builder, 2026-11-24); pushing `main` is a plan
   task.
3. Set the repo variable `RADARIX_OAUTH_CLIENT_ID`.
4. Push `v1.0.0-rc.1`, install it and run the gate check (Decisions, 1); then push
   `v1.0.0`, and commit the first cask to the tap with the release's checksum (or let
   the builder prepare that commit).
5. Review and merge the noix-docs and noix.dev changes (their own repos and branches;
   noix-docs' default branch is `develop`).

## Decisions from the builder check (designer's calls, owner may override)

1. **Signing contingency and gate.** A team-prefixed App Group is expected to need no
   provisioning profile with Developer ID (the app is not sandboxed, the widget is). This
   is proven, not assumed: before `v1.0.0`, a pre-release (`v1.0.0-rc.1`) is installed
   from its DMG on this Mac and the owner checks that the app launches without a
   Gatekeeper warning, keeps its data across a relaunch, and that the widget shows data.
   If the group needs a profile, the plan adds an owner step (Developer ID provisioning
   profiles for app and widget, as secrets) and the script embeds them. This is the one
   point where the plan stops for the owner.
2. **Pre-releases are the test path.** A tag containing `-` builds, signs, notarizes and
   publishes a GitHub pre-release, but skips the tap bump and the Discord announcement.
   No dry-run flag and no throwaway repo.
3. **First cask.** The tap bump step checks whether `Casks/radarix.rb` exists in the tap;
   if not, it skips with a notice and the workflow stays green. Right after `v1.0.0` the
   cask is committed to the tap by hand with the real version and checksum. No
   placeholder cask is ever public.
4. **History.** `NoiXdev/radarix` gets the full local history including `docs/specs` and
   `docs/plans`, as macSCP and MacCommander publish theirs. Commits are authored as
   `hello@noidee.dev`. The 1.0.0 changelog covers all commits so far, like the siblings'
   first releases. README and repo files are finished before the first push.
5. **Team and identity.** Same team and Developer ID Application certificate as macSCP
   (team `5V8ZCK434F`); the script finds the identity in the imported keychain rather
   than hardcoding the name.
6. **Workflow sources.** Same pinned action SHAs and `macos-latest` runner as macSCP;
   XcodeGen installed with Homebrew in CI.
7. **Order across repos.** noix.dev pages and noix-docs are written in the same cycle.
   noix-docs takes its tagline from the EN project page draft. Merge order: noix-docs
   first (deployed), then the noix.dev project page and launch post once `v1.0.0` is
   public, with `docs:`, `download:` and `status: live` set then.

## Left to the builder

Exact script structure, Xcode selection on the runner, build-number scheme, whether the
update check persists its ETag, popover placement details within the stated rule, doc
page split and wording, and the comparison table on the project page (only if fair).
