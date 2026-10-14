---
name: debug
description: "**MUST be invoked** before you change code to fix a failure whose cause you have not proven. NEVER edit until a reproduction shows the defect. Skipping it means a symptom gets patched, the cause survives, and the fix ships with no test to stop it coming back. Find and prove the root cause of a failure — a failing test, an error, wrong behavior, a regression: reproduce it, narrow it, confirm the cause, then hand over the fix with a test that fails without it."
category: practice
---

# Debug

Find out why something fails, prove it, and leave a test that catches it.

## Mindset

- **Reproduce before you reason.** A failure you cannot trigger on demand is a rumor. Get a reliable reproduction first, even a slow one.
- **The cause, not the symptom.** A null check where the null appears hides a bug upstream. Keep asking why the bad state exists until the answer is in code you control.
- **One hypothesis at a time.** State it, predict what you will see if it is true, then test the prediction. Change one thing per experiment.
- **Evidence over intuition.** Logs, a debugger, a bisect, a failing assertion. "It looks like" is a hypothesis, not a finding.
- **Distrust the recent change, then check it.** Most regressions come from the last thing that moved. Confirm with history, do not assume it.

## Inputs

- **The failure** — what happens, what should happen instead, and the exact error text or output.
- **Where it happens** — environment, branch or version, data, configuration, and how often.
- **What changed** — recent commits, dependency updates, configuration or data changes, if known.

When a work item is referenced, read it and all its comments. Earlier investigation often lives there.

## Procedure

1. **Reproduce.** Trigger the failure on demand. Reduce it to the smallest input, the fewest steps, and the narrowest test that still fails. If you cannot reproduce it, halt.
2. **Narrow.** Shrink the search space with evidence. Bisect history (`git bisect`) when it used to work. Bisect the code path with logs or a debugger when it never did. Write down each hypothesis and its result as you go.
3. **Prove the cause.** Show the line or condition that produces the bad state, and explain how. Confirm it: fix that cause alone and the reproduction passes, revert the fix and it fails.
4. **Encode it.** Turn the reproduction into an automated test that fails for the cause you found, not for a side effect.
5. **Hand over the fix.**
   - **A change that opens a pull request:** follow the `develop` skill with the failing test as the contract. Put the root cause in the pull request body.
   - **A small, fully specified fix that opens no pull request:** follow the `quick-edit` skill.
   - **Report the cause either way:** what failed, why, the proof, and the fix. If a work item is in play, **comment on the work item** with the root cause.

## When to halt

- The failure does not reproduce. Report what you tried and what you need, such as data, access, or exact steps. Do not fix from guesswork.
- The cause is outside the code you own, such as a dependency, a platform or an upstream service. Report it with the evidence and the reproduction. Ask whether to work around it.
- The fix would change behavior that other code relies on. Stop and confirm the intended behavior first.

## Composition

**Check what is installed. Never assume a tool skill is absent.** A tool skill is inert
until you invoke it. A rule is already in context. See `global.md` → Tool skills for
which is which.

- **`develop`** owns the fix once it opens a pull request. **`quick-edit`** owns a fix
  that does not.
- **`github-projects`** — invoke it before you comment on a work item or transition one.
- **The `development` rule** sets the testing strategy the reproduction test follows.

Only when no tracker is available: deliver the root cause report in the conversation, and
say so.
