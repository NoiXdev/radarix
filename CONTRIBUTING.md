# Contributing to Radarix

Thanks for wanting to help. Bug reports, ideas and pull requests are all
welcome.

## Before you start

- **Bugs and ideas:** open an issue with one of the templates. For a bug,
  the steps to reproduce and your macOS and Radarix versions save a lot of
  back and forth.
- **Larger changes:** open an issue first and describe what you have in
  mind, so we can agree on the direction before you spend time on code.
- **Security problems:** do not open a public issue. See
  [SECURITY.md](SECURITY.md).

## Set up

Follow [Build from source](README.md#build-from-source) in the README. In
short: install XcodeGen, copy `Config/Local.xcconfig.example` to
`Config/Local.xcconfig`, run `xcodegen generate` and open
`Radarix.xcodeproj`. The Xcode project is generated, so it is not checked
in. Change `project.yml` instead.

A personal access token is enough to sign in during development. You do
not need your own OAuth app.

## Where things live

| Path | What it holds |
|---|---|
| `Packages/RadarixKit` | The core: GitHub access, sync, state, filtering, persistence. Most logic and all tests live here. |
| `App` | The macOS app: windows, menu bar, settings, notifications. |
| `Widget` | The widget extension. |
| `Config` | Build settings. Your own `Local.xcconfig` stays untracked. |
| `scripts/release` | Builds, signs and notarizes a release. CI runs it on a version tag. |

## Making a change

- Put new logic in `RadarixKit` with a test, so the app layer stays thin.
  The tests use Swift Testing.
- Run the tests and a build before you open the pull request:

  ```sh
  cd Packages/RadarixKit && swift test
  ```

  ```sh
  xcodegen generate && xcodebuild -project Radarix.xcodeproj -scheme Radarix build
  ```

- The project builds in Swift 6 language mode with strict concurrency, and
  it builds without warnings. Keep it that way.
- User-visible text goes through the string catalog
  (`App/Resources/Localizable.xcstrings`, and the widget's own catalog).
  Add every new string in English and German. If you do not speak German,
  say so in the pull request and we will add it.
- Never put a real token, password or account name in code, tests or
  screenshots.

## Commits and pull requests

- Commits follow [Conventional Commits](https://www.conventionalcommits.org/)
  (`feat:`, `fix:`, `docs:`, …). The changelog and release notes are built
  from them.
- Keep a pull request to one topic. The template asks what changed, why,
  and how you checked it.
- CI runs the tests and an unsigned build on every pull request. It needs
  to be green before a merge.

## License

By contributing, you agree that your contribution is licensed under the
[MIT License](LICENSE), like the rest of the project.
