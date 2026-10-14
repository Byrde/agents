---
name: quick-edit
description: "**MUST be invoked** before a small, fully specified edit that opens no pull request: a rename, a configuration or formatting change, or a fix whose cause `debug` has already proven. NEVER take a reported bug straight here: it goes to `debug` first. NEVER let an edit grow past one file or into a design question without switching to `develop`. Skipping it means a small edit goes unverified, or quietly becomes a feature with no tests and no review. Make the smallest change that does what was asked, check it, and report exactly what changed."
category: practice
---

# Quick edit

Make a small, fully specified change, check it, and stop.

## Mindset

- **Specified means specified.** The request already says what to change and to what. If you must decide the behavior, it is not a quick edit.
- **Smallest diff that works.** Change what was asked and nothing near it. No cleanup on the side, no reformatting of untouched lines.
- **Still verified.** A small edit can still break the build. Run the narrowest check that covers it.
- **Know the exit.** The moment the edit spreads past one file, needs a decision, or should go through review, it belongs to `develop`.

## Inputs

- **What to change** — the file, the place, and the new content or behavior.
- **How to know it worked** — the check to run, or the visible result to confirm.

## Procedure

1. **Confirm it qualifies.** One file, behavior fully specified, no pull request. If any of these fails, switch to `develop` and say why. If the request reports something broken and no cause has been proven, switch to `debug`.
2. **Edit.** Make the change exactly as specified. Match the surrounding code and its conventions.
3. **Check.** Run the narrowest check that covers the edit: the test for that file, the linter, a build, or the command whose output shows the change. Read the result. Do not assume it.
4. **Report.** Show what changed, in one or two lines or as the diff, and the check you ran with its result.

## When to halt

- The request leaves the behavior open. Ask, or switch to `develop`.
- The edit needs a second file, a new dependency, or a schema or interface change. Switch to `develop`.
- The check fails for a reason you did not cause. Report it and leave the edit in place or reverted, as the user prefers. Do not chase it inside a quick edit.

## Composition

**Check what is installed. Never assume a tool skill is absent.** A tool skill is inert
until you invoke it. A rule is already in context. See `global.md` → Tool skills for
which is which.

- **`develop`** takes over when the edit outgrows this skill, including any change that
  opens a pull request.
- **`debug`** hands a fix here when the fix is small and fully specified.
- **The `development` rule** still applies to every line you change.
