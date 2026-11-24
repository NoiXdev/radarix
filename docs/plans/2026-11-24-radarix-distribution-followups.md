# Radarix distribution: follow-ups after 1.0.0

Plan 3 (`2026-11-24-radarix-distribution.md`) shipped Radarix 1.0.0 on
2026-11-24:

- the public repo `NoiXdev/radarix`;
- the signed and notarized DMG;
- the cask in `NoiXdev/homebrew-tap`;
- the update check.

The docs (`noix-docs`, branch `docs/radarix`) and the noix.dev project page
and launch post (branch `radarix`) are ready on their branches. Merging them is
the owner's call. Merge the docs first and deploy them, then set `docs:` on the
noix.dev project and merge it.

This file lists what the reviews deferred. Items fixed before the release are
left out.

## Release pipeline

- **macSCP has the same publish step that failed for Radarix rc.1.**
  - On its second call, `softprops/action-gh-release` does not find the draft
    by its tag. It creates a second release and then fails with
    `already_exists`.
  - Radarix now publishes with `gh release upload` and `gh release edit`.
    Port that change to macSCP.
  - macSCP's private vulnerability reporting is also off.
- **The rc.1 leftovers are still on GitHub:** an empty published pre-release
  and a draft with the DMG. Delete both once the owner agrees. The tag can stay.
- **The changelog push to `main` is rejected if `main` moves during the job.**
  The fix is a pull and rebase before the push.
- **A zero-match Xcode glob fails without an `::error::`.**
- **`scripts/release` has two bare `codesign` reads under `set -e`** (the
  unsigned print loop and the entitlements read). They can stop the script
  without a message.
- **A failed export leaves no detailed log in CI.**
- **The archive/export certificate and the DMG signing certificate could
  differ.** Assert that they are the same.
- **The runner image ships Xcode 26.6 (Swift 6.3.3), and the maintainer builds
  with Xcode 27.** Code has to build on both, and Swift 6.3 crashed once on
  valid code (`GeneralSettings.swift`). When the image gets Xcode 27, consider
  pinning it.

## Update check

- `checkNow` ignores `isEnabled`.
- The loop may hold `self` strongly across its sleep.
- An error is logged before the generation check, which adds noise after the
  check is turned off.
- Some tests use fixed sleeps, so they depend on CI timing.
- An unparsable app version hides the toggle as well as the check.
- The `User-Agent` uses the version's implicit description.
- There is no automated test of the app wiring, from settings to checker to
  hint.
- The popover row's VoiceOver label is unverified. Check it in a VoiceOver
  pass.

## Docs and site

- **The noix-docs default branch is `develop`, which is 398 commits behind
  `main`.** The Radarix docs branch starts from `main`. Point its PR at `main`
  or bring `develop` up to date.
- **The issue chooser's docs link (`docs.noix.dev/radarix`) works only once
  the docs are deployed.**
- **The taglines were shortened to the noix.dev 70-character limit.** If the
  wording changes, update `products.ts` and the tap README row with it.
