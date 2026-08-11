---
name: develop
description: "**MUST be invoked** before the first edit of any change that will open a pull request. NEVER start implementing and decide later that the work was too small to need it. Skipping it means no contract tests, no work-item transition, and no review request, because this skill is what consults the tracker and source control. Invoke once per slice, not once per session — its procedure ends at Ship and does not carry forward. Implement a feature or fix from clear requirements using TDD: contract tests first, implement to green, refactor within scope, halt on ambiguity."
category: practice
---

# Develop

Implement work that has clear, unambiguous requirements.

## Mindset

- **Crystal clear before code.** Don't write implementation code until requirements are clear and complete for the slice at hand. List implicit assumptions and resolve them with the user before coding anything substantive.
- **Test-driven, always.** The first step is contract tests that mirror the acceptance criteria. Implement to green. Refactor within scope.
- **Halt on ambiguity.** If you hit an edge case, spec contradiction, or technical ambiguity mid-implementation, stop and flag it. Don't power through on assumptions.
- **Stay in scope.** No unrelated cleanup. No drive-by features. Acceptance criteria define done.
- **Standards count.** Follow the always-on `development` rule (installed into your editor's rules dir from `.agents/rules/development.md`) — that's the one place where rigidity is the point.

## Inputs

- **Acceptance criteria** — the conditions that must be true when the work is done.
- **Behavioral context** — data contracts, error handling, scope boundaries, prior architectural or design decisions.

When a work item is referenced, read it and all its comments — that's where prior decisions live.

## Procedure

1. **Align on the work.** Confirm what's being built. If a work item is referenced, read it through and verify it isn't already implemented. List assumptions and ambiguities; resolve them with the user. Reflect back what will be built and what the tests will cover — confirm before coding.
2. **Set up.** If the change ships through code review, **create a branch in a dedicated worktree** (`.worktrees/<branch>`) following the project's conventions — isolating the work so parallel efforts don't collide. Trivial `patch/`-class fixes may stay in the main checkout. Install dependencies in the new worktree before building, and tear it down once the PR merges (see the `github-source-control` rule for worktree mechanics). If a work item is in play, **transition the work item** to its in-progress state.
3. **Implement.** Write contract tests that encode the acceptance criteria. Implement to green. Refactor within scope. Follow the architectural standards. If you hit ambiguity mid-flight, stop and flag it on the work item or in the conversation — don't guess.
4. **Ship.** **Open the pull request** with a body covering summary, how the change satisfies acceptance criteria, test evidence, risks and follow-ups, and a link to the work item if one exists. If a work item is in play, **transition the work item** to its post-PR state and **comment on the work item** with what was done, the PR link, and anything a reviewer or tester should know.

## When to halt

- Requirements aren't clear enough to write tests against — go back to alignment, don't fake your way through.
- A spec contradiction or unforeseen edge case surfaces mid-implementation — flag it, wait for resolution.
- The work has expanded beyond the acceptance criteria — pause and confirm scope before continuing.

## Composition

**Check what is installed before you start.** Read the available skill list. Never
assume a tool skill is absent, and never infer it from the fact that nobody mentioned
it.

Two mechanisms, and they are not the same:

- A **tool skill** must be invoked. It is inert until you load it.
- A **rule** is already in context when installed. Follow it. There is nothing to
  invoke.

What this skill routes to:

- **`github-projects`** (tool skill) — if available, you MUST invoke it before you
  transition a work item or comment on one.
- **The `github-source-control` rule** — always on when installed, so it is already in
  context. It governs branches, worktrees, pull request bodies and review requests.
  Follow it. There is nothing to invoke, and nothing about it is optional because the
  change felt small.
- **The Figma↔code component map** (e.g. `figma-code-map.json`) — if the project keeps
  one, consult it before building UI. Find the component to extend rather than adding
  a second one. Update its entry when you add or rename a component, then run
  `.agents/tools/figma-code-map-lint.sh` and fix any failure.

Only when no tracker is available: gather requirements conversationally and deliver
code with a written summary. Only when no source control is available: deliver code
and tests in the conversation. Say which case applies.

