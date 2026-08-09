# Contributing to Ultra-Trail Dashboard

This is maintained by one person, so the most useful contribution is usually a
precise report rather than a large patch. Everything below exists to make a
change reviewable, not to add ceremony.

## Before anything else

A security problem does not belong in a public issue. Use the **Security** tab,
then **Report a vulnerability**. What counts as one here is in
[SECURITY.md](SECURITY.md).

## Reporting a bug

Open an issue with the bug template. What makes a report actionable:

- the exact steps, from a clean state, and what you expected instead
- the version, and the platform it ran on
- a file or a screenshot when the trigger is one specific input

If the input holds personal data, describe how to build an equivalent one
rather than attaching it.

## Suggesting a feature

Open an issue with the feature template and describe the problem before the
solution. A feature that does not pull its weight does not ship: that is the
project's standard, not a rejection of the idea.

## Pull requests

Open an issue first for anything beyond a typo or a one-line fix, so the design
is agreed before the work happens.

Once that is settled:

1. Branch from `main`.
2. Keep the change to one concern. Two unrelated fixes are two pull requests.
3. Add a `CHANGELOG.md` entry, and bump the version where the project keeps it.
4. Verify it, and say in the pull request how you did.

## Building and checking locally

Needs the [Connect IQ SDK](https://developer.garmin.com/connect-iq/sdk/) 9.2.0
or later and a developer key.

```bash
monkeyc -o UltraTrailDashboard.prg -f monkey.jungle -y developer_key -d fenix7 -O2
```

The unit tests live in `source-test/`, pulled in only by `test.jungle`, so a
release build never sees them. Start the simulator, then:

```bash
monkeyc -f "monkey.jungle;test.jungle" -o bin/test.prg -y developer_key -d fenix7 --unit-test && monkeydo bin/test.prg fenix7 -t
```

**Run them for any change to the models.** They check values worked out by
hand, not values read back off the code: a sign error in the durability decay
or a factor of 1000 in the energy balance does not crash anything, it just
quietly tells the athlete a lie.

CI cannot compile, because the SDK needs Garmin's licence accepted
interactively. What it does check runs locally in a second:

```bash
python3 .github/scripts/check_resources.py
```

That parses every resource XML, checks the Italian translation against the
default language, and checks the version in `manifest.xml` against the newest
released entry in `CHANGELOG.md`. String ids that stay in English on purpose,
such as the FIT field labels, are listed in `.github/untranslated.txt`.

## Working on the models

`MinettiCost.mc` is the single source of truth for the energy cost of a metre
at a given grade. If a change needs that cost, call it: a second copy of the
formula is how the two paths drift apart.

The three physiological models are deliberately independent. None of them knows
the others exist; each integrates its own state and declares how long until
*it* fails. Keep it that way: a fourth model should touch none of the three.

A change to a model needs a number in the pull request, not an argument. Say
which published result or which measured run the new behaviour matches.

## House rules

- **English only**, in code comments, commit messages and user-facing strings.
- **Commit messages** say what changed and why. The subject line is imperative
  and under 72 characters, the body wraps at 72 and explains the reasoning that
  is not obvious from the diff.
- **No generated or vendored files** in a commit unless the project already
  tracks them.
- **No credentials, keys or personal data**, including in test fixtures.

## Licence

By contributing you agree that your work is distributed under the licence in
[LICENSE](LICENSE).
