# Radarix

[![Latest release](https://img.shields.io/github/v/release/NoiXdev/radarix?label=release)](https://github.com/NoiXdev/radarix/releases/latest)
[![macOS 15+](https://img.shields.io/badge/macOS-15%2B-555)](#install)
[![License: MIT](https://img.shields.io/github/license/NoiXdev/radarix?label=license)](LICENSE)

**A Mac app that watches your GitHub repositories for new and updated pull
requests and issues.**

Radarix keeps one list of what needs your attention, across all your
repositories and accounts. It lives in the menu bar, and it never decides
for you what you have seen.

## What it does

- **All your repositories.** Watches your own repositories and those of
  your organizations for new and updated pull requests and issues.
- **Several accounts in one list.** Sign in with, for example, a private
  and a work account. A repository that more than one account can see
  shows once.
- **Nothing is "seen" by itself.** Showing an item does not mark it. An
  item is marked seen when you select or open it, in the list, the popover
  or a notification, or when you mark it, or a whole repository, as seen
  yourself.
- **Menu bar, main window, notifications.** A menu bar icon with a
  popover for a quick look, a main window for the full list, and
  notifications for new activity.
- **A desktop widget** that shows what is waiting for you.
- **Two ways to sign in.** Sign in with GitHub, or use a personal access
  token.
- **Your credentials stay on your Mac.** Tokens are kept only in the macOS
  Keychain. There is no Radarix account, no cloud and no telemetry. The app
  talks only to GitHub.

## Install

With [Homebrew](https://brew.sh):

```sh
brew tap noixdev/tap
brew install --cask radarix
```

Or download the DMG from the
[releases page](https://github.com/NoiXdev/radarix/releases), open it, and
drag **Radarix** into **Applications**.

Requires macOS 15 or later. The app is signed and notarized.

## Sign in

Open **Settings → Accounts** and add an account.

- **Sign in with GitHub.** Follow the steps in the window. This is the
  easiest way.
- **Personal access token.** Under **Advanced**, paste a token. It needs:
  - a classic token: the `repo` and `read:org` scopes;
  - a fine-grained token: read access to metadata, issues and pull
    requests.

You can add more accounts the same way. Radarix stores each token in the
macOS Keychain and nowhere else.

Radarix checks GitHub every 2, 5, 10, 15 or 30 minutes. Choose the interval
under **Settings → General**.

## Updates

Radarix tells you in the app when a newer version is available. It never
downloads or installs anything by itself. You can turn the check off in
the settings.

With Homebrew:

```sh
brew upgrade --cask radarix
```

What changed in each release is listed in [CHANGELOG.md](CHANGELOG.md).

## Build from source

You need macOS 15 or later, Xcode, and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
brew install xcodegen
cp Config/Local.xcconfig.example Config/Local.xcconfig
```

Edit `Config/Local.xcconfig`: set your development team and signing
identity, and optionally an OAuth client ID for "Sign in with GitHub".
Without a client ID, the app still works with a personal access token.

```sh
xcodegen generate
open Radarix.xcodeproj
```

Build and run the **Radarix** scheme in Xcode. To build from the command
line, use `xcodebuild -project Radarix.xcodeproj -scheme Radarix build`.

The core logic lives in a Swift package. Run its tests with:

```sh
cd Packages/RadarixKit && swift test
```

## Contributing

Bug reports, ideas and pull requests are welcome. See
[CONTRIBUTING.md](CONTRIBUTING.md).

## Security

Found a vulnerability? Please report it privately. See
[SECURITY.md](SECURITY.md).

## License

[MIT](LICENSE)
