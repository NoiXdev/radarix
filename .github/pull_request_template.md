<!--
Short is fine. The headings below are what a reviewer needs; everything
else you want to say is welcome underneath them.
-->

## What this changes

<!-- One or two sentences. What behaviour is different after this than before? -->

## Why

<!--
The situation that made it necessary. If it fixes a reported problem, link the
issue. If you measured something, put the number here rather than "it was
slow". A number is checkable and an adjective is not.
-->

## How it was verified

<!--
Not "tests pass": which command, and what it printed. The kit tests are:

    cd Packages/RadarixKit && swift test

If a change cannot be covered by a test, say so and say why. That is a
finding, not an omission.
-->

## Checklist

- [ ] New behaviour comes with a test, and I saw that test fail before the change.
- [ ] The kit tests are green, and the build produces no new warnings.
- [ ] No token, password or real account name appears in the diff, including in test fixtures and in expectation messages.
- [ ] User-visible strings go through the string catalog, and every language has the new key.
- [ ] Commits follow [Conventional Commits](https://www.conventionalcommits.org/). The changelog is generated from them.
- [ ] Anything a user would notice is written into the user documentation, or the PR says why it is not.
