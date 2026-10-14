---
name: review
description: "**MUST be invoked** before you review code, a diff, a branch or a pull request. NEVER approve from a skim of the diff alone. Skipping it means the review checks style while the defect, the missing test, or the broken contract goes through. Review a change for correctness, risk and fit: read it against its intent, trace what it touches, and report findings ranked by severity with the evidence for each."
category: practice
---

# Review

Read a change the way the next incident will: looking for what it breaks.

## Mindset

- **Intent first.** A change is correct only against what it was meant to do. Read the work item or the pull request body before the diff.
- **The diff is not the change.** What a change affects includes the callers, the data and the contracts it touches. Read past the edges of the diff.
- **Severity, not volume.** One real defect outweighs twenty style notes. Rank findings, and leave style to the formatter and the linter.
- **Evidence for every finding.** Name the line, the input and the outcome. "This might be a problem" is not a finding until you can say when it fails.
- **Standards count.** The always-on `development` rule is part of the review surface. A deviation is a finding, not a preference.

## Inputs

- **The change** — a pull request, a branch, a commit range, or a diff.
- **Its intent** — the work item, the pull request body, or the author's own description.
- **The scope** — a full review, or a focus the requester names, such as security, performance or the migration.

When a work item is referenced, read it and all its comments.

## Procedure

1. **Frame.** Say what the change is meant to do and what the review will cover. Confirm the scope when the request is vague.
2. **Read for correctness.** Check that the change does what its intent says. Trace each changed path through its callers and the data it touches. Check the error paths, the edge cases and concurrency, not only the happy path.
3. **Read for risk.** Look at security (input handling, authorization, secrets), data (migrations, compatibility, loss), operations (configuration, rollout, rollback), and performance where the change touches a hot path.
4. **Read the tests.** Check that each behavior the change adds or alters has a test, and that each test fails without the change. A green run proves nothing about an untested path.
5. **Check fit.** Check the change against the `development` rule: structure, dependencies, separation of concerns. Look for duplication of something that already exists.
6. **Report.** List findings by severity: **blocking** (wrong, unsafe, or untested behavior), **should fix**, and **consider**. Give each one the location, what goes wrong, a reproduction or reasoning, and a suggested fix. Say what you checked and found sound. On a pull request, **leave review comments** on the lines they concern, and give an overall verdict.

## When to halt

- The intent is unknown and cannot be inferred. Ask for it before you judge correctness.
- The change is too large to review well. Say so, and propose a split or a focus.
- The change cannot be read or run, such as a missing branch or a broken build. Report it, do not review from guesses.

## Composition

**Check what is installed. Never assume a tool skill is absent.** A tool skill is inert
until you invoke it. A rule is already in context. See `global.md` → Tool skills for
which is which.

- **The `github-source-control` rule** owns review comments on a pull request and the
  review verdict.
- **`test`** validates a build against its acceptance criteria. This skill reviews the
  change itself. Use both when a change needs both.
- **The `technical-writing` rule** applies to review comments.

Only when no source control is available: deliver the findings in the conversation, and
say so.
