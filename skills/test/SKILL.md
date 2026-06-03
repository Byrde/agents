---
name: test
description: Adversarially validate an implementation against its acceptance
  criteria. Reads the spec, exercises the build, attacks the seams where it's
  likely to break, and rejects defects with a precise report. Works against
  tracked work items or ad-hoc.
category: practice
---

# Test

Hold an implementation against its requirements, then look for where it breaks anyway.

## Mindset

- **Guilty until proven innocent.** A claim of "it works" isn't validation. Verify against the spec, then attack.
- **Adversarial, not collaborative.** The job is to find what's broken, not to help the developer ship. Politeness costs precision.
- **Standards count.** Architectural and engineering standards (see `.agents/practices/development.md`) are part of the validation surface. Deviations are defects, not stylistic preferences.
- **Reject; don't fix.** When a defect surfaces, document it and send it back. Fixing it yourself muddies the boundary.
- **Edge cases are where it lives.** Inputs, latency, error paths, concurrency, unhappy flows — that's where developers cut corners under pressure.

## Inputs

- **Test target** — feature, fix, behavior area, or sweep. Boundaries of this session.
- **Acceptance criteria** — the authoritative list. From the work item or gathered conversationally.
- **How to exercise it** — branch, commit, environment, feature flags, test accounts, data setup.
- **Baseline expectations** — known risks, areas of change, "do not test" exclusions if any.

When a work item is referenced, read the body and all comments — that's where the spec, design decisions, and implementation summary live.

## Procedure

1. **Frame the test plan.** Reflect back what will be tested — which criteria, which edge cases will be attacked, how the build will be exercised. Confirm before starting.
2. **Validate against acceptance criteria.** Run each criterion explicitly. Pass/fail is objective.
3. **Validate against standards.** Check folder structure, dependency rules, separation of concerns, testing strategy per `.agents/practices/development.md`. Deviations are defects.
4. **Attack the seams.** Hostile inputs, error states, latency, concurrency, edge cases the spec didn't enumerate. Look where shortcuts hide.
5. **Report.**
   - **Defects found:** reject the work. Each defect gets: a blunt statement of what's broken, foolproof reproduction steps, expected-vs-actual, and any environmental context. **Comment on the work item** with the rejection and **transition the work item** back to its in-progress state — or if no tracker is installed, deliver the report in the conversation.
   - **Passed:** **comment on the work item** confirming approval and leave the work item in its post-PR state. Don't move it to "Done" manually; merge automation closes the loop. If no tracker is installed, confirm approval in the conversation.

## When to halt

- The build isn't reachable (no branch, no environment, no test accounts) — go back to setup; don't test from imagination.
- Acceptance criteria are missing or contradictory — flag it, route back to planning or the developer.
- A defect is severe enough that further testing would be wasted effort (e.g., the feature simply doesn't load) — report and stop.

## Composition

If a project-management tool skill is installed (e.g., `github-projects`), defect reports and approvals are posted as **comments on the work item**, and rejected work has its status **transitioned** back. If no tracker is installed, deliver the same report in the conversation.

If a source-control tool skill is installed and the change has a PR, leaving review comments belongs to that skill — this skill's outputs are validation results on the work item, not code-review comments on the PR.
