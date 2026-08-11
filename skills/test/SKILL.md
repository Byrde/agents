---
name: test
description: "**MUST be invoked** before you claim an implementation meets its acceptance criteria. NEVER assert that work is validated from a passing test run alone. Skipping it means the seams go unattacked and a defect ships looking green. Adversarially validate an implementation against its acceptance criteria: read the spec, exercise the build, attack where it is likely to break, and reject defects with a precise report. Works against tracked work items or ad-hoc."
category: practice
---

# Test

Hold an implementation against its requirements, then look for where it breaks anyway.

## Mindset

- **Guilty until proven innocent.** A claim of "it works" isn't validation. Verify against the spec, then attack.
- **Adversarial, not collaborative.** The job is to find what's broken, not to help the developer ship. Politeness costs precision.
- **Standards count.** Architectural and engineering standards (the always-on `development` rule) are part of the validation surface. Deviations are defects, not stylistic preferences.
- **Reject rather than fix.** When a defect surfaces, document it and send it back. Fixing it yourself muddies the boundary.
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
3. **Validate against standards.** Check folder structure, dependency rules, separation of concerns, testing strategy per the `development` rule. Deviations are defects.
4. **Attack the seams.** Hostile inputs, error states, latency, concurrency, edge cases the spec didn't enumerate. Look where shortcuts hide.
5. **Report.**
   - **Defects found:** reject the work. Each defect gets a blunt statement of what is broken, foolproof reproduction steps, expected against actual, and any environmental context. **Comment on the work item** with the rejection. **Transition the work item** back to its in-progress state. If no tracker is installed, deliver the report in the conversation.
   - **Passed:** **comment on the work item** confirming approval and leave the work item in its post-PR state. Don't move it to "Done" manually. Merge automation closes the loop. If no tracker is installed, confirm approval in the conversation.

## When to halt

- The build isn't reachable (no branch, no environment, no test accounts) — go back to setup. Never test from imagination.
- Acceptance criteria are missing or contradictory — flag it, route back to planning or the developer.
- A defect is severe enough that further testing would be wasted effort (e.g., the feature simply doesn't load) — report and stop.

## Composition

**Check what is installed. Never assume a tool skill is absent.** A tool skill is inert
until you invoke it. A rule is already in context. See `global.md` → Tool skills for
which is which.

- **`github-projects`** — invoke it before you post a defect report, record an approval,
  or transition rejected work back.
- **The `github-source-control` rule** owns review comments on a pull request. This
  skill's output is a validation result on the work item, not a code review.

Only when no tracker is available: deliver the same report in the conversation, and say
so.

