---
name: develop
description: Implement a feature or fix from clear requirements using TDD.
  Reads and updates work items when a tracker is installed; opens pull requests
  when source control is installed; otherwise delivers code and tests in the
  conversation. Writes contract tests first, implements to green, refactors
  within scope, halts on ambiguity.
category: practice
---

# Develop

Implement work that has clear, unambiguous requirements.

## Mindset

- **Crystal clear before code.** Don't write implementation code until requirements are clear and complete for the slice at hand. List implicit assumptions and resolve them with the user before coding anything substantive.
- **Test-driven, always.** The first step is contract tests that mirror the acceptance criteria. Implement to green. Refactor within scope.
- **Halt on ambiguity.** If you hit an edge case, spec contradiction, or technical ambiguity mid-implementation, stop and flag it. Don't power through on assumptions.
- **Stay in scope.** No unrelated cleanup. No drive-by features. Acceptance criteria define done.
- **Standards count.** Follow the architectural rules in `.agents/practices/development.md` — that's the one place where rigidity is the point.

## Inputs

- **Acceptance criteria** — the conditions that must be true when the work is done.
- **Behavioral context** — data contracts, error handling, scope boundaries, prior architectural or design decisions.

When a work item is referenced, read it and all its comments — that's where prior decisions live.

## Procedure

1. **Align on the work.** Confirm what's being built. If a work item is referenced, read it through and verify it isn't already implemented. List assumptions and ambiguities; resolve them with the user. Reflect back what will be built and what the tests will cover — confirm before coding.
2. **Set up.** If the change ships through code review, **create a branch** following the project's conventions. If a work item is in play, **transition the work item** to its in-progress state.
3. **Implement.** Write contract tests that encode the acceptance criteria. Implement to green. Refactor within scope. Follow the architectural standards. If you hit ambiguity mid-flight, stop and flag it on the work item or in the conversation — don't guess.
4. **Ship.** **Open the pull request** with a body covering summary, how the change satisfies acceptance criteria, test evidence, risks and follow-ups, and a link to the work item if one exists. If a work item is in play, **transition the work item** to its post-PR state and **comment on the work item** with what was done, the PR link, and anything a reviewer or tester should know.

## When to halt

- Requirements aren't clear enough to write tests against — go back to alignment, don't fake your way through.
- A spec contradiction or unforeseen edge case surfaces mid-implementation — flag it, wait for resolution.
- The work has expanded beyond the acceptance criteria — pause and confirm scope before continuing.

## Composition

If a project-management tool skill is installed (e.g., `github-projects`), work-item operations (**transition**, **comment on work item**) go through that skill. If a source-control tool skill is installed (e.g., `github-source-control`), branch creation and PR operations go through that skill.

If no tracker is installed, treat the work as ad-hoc — gather requirements conversationally, skip the work-item steps, and deliver code with a written summary in the conversation. If no source-control tool is installed, deliver code and tests in the conversation without a branch or PR.

If the project keeps a **Figma↔code component map** (e.g., `figma-code-map.json`; maintained via `figma-design-system`), consult it before building UI to find the existing component to implement or extend, and update its entry when you add or rename a component — keep the design↔code links current.
