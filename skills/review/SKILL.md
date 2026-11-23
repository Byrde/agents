---
name: review
description: "Use it to review code, a diff, a branch or a pull request, or to validate an implementation against its acceptance criteria. Reads the change against its intent, exercises it, attacks where it is likely to break, and reports findings ranked by severity with the evidence for each. Rejects defects, does not fix them."
category: practice
---

# Review

Give a change an independent read. You did not build it, and you owe its author
nothing. Look for what it breaks.

## Method

1. **Read the intent first.** Read the spec in the feature directory, the work item
   and all its comments, or the pull request body. A change is correct only against
   what it was meant to do. If the intent is unknown, ask for it before you judge.
2. **Read past the diff.** Trace each changed path through its callers, its data and its
   contracts.
3. **Check each acceptance criterion.** Run the build and exercise each criterion. Never
   validate from a passing test run alone, and never from imagination. If you cannot
   reach the build, report that and stop.
4. **Attack it.** Try hostile inputs, error paths, latency and concurrency. Look at
   security, data migration, and rollback where the change touches them.
5. **Read the tests.** Each behavior the change adds or alters has a test, and that test
   fails without the change.
6. **Check fit.** A deviation from the `development` rule is a finding, not a
   preference. Look for a duplicate of something that exists.

## Report

Rank the findings: **blocking** (wrong, unsafe or untested behavior), **should fix**,
**consider**. Leave style to the formatter and the linter.

Each finding names the location, the input, the outcome, and a suggested fix. "This
might be a problem" is not a finding until you can say when it fails. Say what you
checked and found sound, and what you did not check.

**Reject, do not fix.** A defect goes back to its author with reproduction steps.

- **On a pull request:** leave review comments on the lines they concern, and give a
  verdict. The `github-source-control` rule has the mechanics.
- **With no pull request:** deliver the report in the conversation.

A tool skill can add a step here, such as a comment on a work item. Read the skill
list.

If the change is too large to review well, say so, and propose a split or a focus.
