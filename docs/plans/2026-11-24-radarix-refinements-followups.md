# Radarix 1.1 refinements: follow-ups

Plan `2026-11-24-radarix-refinements.md` is implemented on `feat/radarix-refinements`. This file lists what the reviews deferred and what still needs a person.

## Before release (owner, by eye)

- **Filters:** set chips, quit, and relaunch. The same chips are on.
- **Sidebar badges:** check them in light and dark mode, with one account and with two.
  - Teal (PR) sits near the status green, and pink (issue) near the status red. Confirm they read as distinct.
  - Check the VoiceOver wording.
- **Group by repository:**
  - Turn it on and off, and confirm it is kept across a relaunch.
  - It is hidden on a single repo.
  - With it on, open a notification or deep link to an item: the list scrolls there.
- **Widget:**
  - Add widgets with different filters in every family.
  - Check the caption fit in small, and that medium lists 3 items when filtered.
  - Check the "+" on a large repo with more than 100 items.
  - Widgets configured with 1.0.0 still work.
- **Description window:**
  - Space opens it, on the flat list and on the grouped list.
  - Escape closes it, also while the web content has focus.
  - Reopening an item brings its window to the front.
  - File > New offers no description window.
  - An issue with a table, a task list, code and an image renders as on github.com.
  - Links open in the browser, and a `#fragment` link opens the item's page at that anchor.
  - Offline, it shows the excerpt, the error and "Try again".
- **Security check:** temporarily feed the description `<script>document.body.innerHTML='x'</script><a href="javascript:alert(1)">j</a><a href="https://example.com">e</a>`.
  - Nothing runs.
  - `javascript:` does nothing.
  - example.com opens in the browser.
- **CI:** the branch has only been built on Xcode 27. CI builds on Xcode 26.6 / Swift 6.3, and Swift 6.3 crashed once on valid code. CI has to be green before merge.

## Code

- **Snapshot writes:** about 17 ms on the main actor when a selection changes attention (30 repos × 150 items, measured). Coalesce writes, or encode off the main actor.
- **Spinner can stall:** if a description window's entry is nil at first and appears later, the spinner stays. Key the task on `attempt` and `entry != nil`.
- **Untested mapping:** the `WKNavigationType` → `NavigationKind` mapping is untested. It is one line and fails closed.
- **Widget logic untested:** `ScopeIntent.filter`, `init(scope:filter:)` and the caption are untested, because the widget has no test target. Consider moving the mapping into RadarixKit.
- **Duplicated ternary:** the widget's `isLowerBound` ternary is repeated for new and updated.
- **Hand-written decoders:** `FilterSet` and `WidgetSnapshot.ItemEntry` have hand-written decoders. Add a `{}`-decodes-to-defaults test, and remember all four places when adding a field.
- **Stale strings:** the catalog keys "%lld new" and "%lld updated" are unused since `AttentionBadges` was removed.
- **Missing tests in `renderedDescription`:**
  - the "no repo state" branch is not tested separately from "no owner";
  - `renderedBody` has no error-mapping test (it shares the `perform` path).
- **Sidebar badges:** they ignore the filter chips. That is by design (spec §3).
