# Workflow: Work

Take a spec'd work item through implementation and QA validation.

## Jobs

This workflow composes the following jobs, in order:

1. **Software Developer** — `.agents/jobs/develop.md`
2. **QA Specialist** — `.agents/jobs/test.md`

## Tooling

**This workflow operates entirely in GitHub.** All branch creation, issue state transitions, pull requests, and QA reporting must be performed through the GitHub API using the configuration and conventions defined in `.agents/tools/github.md`.

Concretely:
- **Branches** follow the naming conventions in `.agents/tools/github.md` (`feature/`, `bugfix/`, `patch/`).
- **Issue lifecycle** (In Progress → Ready to Test → Done) is managed on the GitHub Project board.
- **Pull requests** follow the format and content requirements in `.agents/tools/github.md`.
- **All communication** (implementation notes, QA results, defect reports) is posted as comments on the relevant GitHub issue.

## Dependencies

### Required Files

These files **must** exist and be fully populated before this workflow can execute. If any are missing or incomplete, **fail immediately** and tell the user what needs to be created.

| File | Purpose |
| --- | --- |
| `.agents/tools/github.md` | GitHub account, repository, project board configuration, and conventions. |

### Work Item (mandatory, no exceptions)

A **fully spec'd GitHub issue** must be identified before execution begins. The issue must have acceptance criteria, and should have any architectural comments from a prior planning workflow.

If no issue is provided and no matching item exists on the project board, **stop** and suggest the user plan some work first. There are no patch exceptions in this workflow — all work flows through a tracked issue.

## Steps

### Step 1 — Developer Review (same context)

**Job:** Software Developer (`.agents/jobs/develop.md`)
**Runs in:** The current conversation context (interactive).

**Procedure:**

1. **Validate dependencies:** Confirm `.agents/tools/github.md` exists and is populated. Fail if not.
2. **Identify the work item:** Confirm the GitHub issue (or patch-exception scope) with the user. Read the issue's description, acceptance criteria, and any architectural comments.
3. **Verify current state:** Check that the issue is not already implemented (merged PRs, closed-as-done, codebase matches criteria). If partially implemented, map what remains.
4. **Extract and verify requirements:** List implicit assumptions or ambiguities. Resolve with the user before proceeding. If gaps require a spec update, halt and route back to planning.
5. **Flag to proceed:** Present the developer's understanding of the work — what will be built, what the tests will cover, and any decisions made. **Wait for explicit user confirmation** before moving to implementation.

**Completion gate:** The user has confirmed the developer's understanding and given the go-ahead.

### Step 2 — Implementation (MUST RUN AS SUBAGENT)

**Job:** Software Developer (`.agents/jobs/develop.md`)
**Runs in:** A sub-agent (isolated context, launched after Step 1 completes).

**Input to sub-agent:**
- The verified requirements and decisions from Step 1.
- The GitHub issue number and repository from `.agents/tools/github.md`.
- The contents of `.agents/practices/development.md`.
- The conventions from `.agents/tools/github.md`.

**Procedure:**

1. **Create branch** following `tools/github.md` conventions.
2. **Move issue** to **In Progress** on the project board.
3. **TDD loop:** Write contract tests encoding the acceptance criteria, implement to green, refactor within scope.
4. **If blocked:** Stop implementation. Comment on the GitHub issue describing the gap and escalate back to the user.
5. **Open PR** following the format in `tools/github.md`.
6. **Update issue:** Move to **Ready to Test**. Comment on the issue with what was done, the PR link, and anything the tester should know.

**Completion gate:** PR is open, issue is in Ready to Test, and the implementation comment is posted.

### Step 3 — QA Validation (MUST RUN AS SUBAGENT)

**Job:** QA Specialist (`.agents/jobs/test.md`)
**Runs in:** A sub-agent (isolated context, launched after Step 2 completes).

**Input to sub-agent:**
- The GitHub issue number, PR number, and repository from `.agents/tools/github.md`.
- The acceptance criteria from the issue.
- The implementation summary comment from Step 2.
- Branch/commit to test against.

**Procedure:**

1. **Baseline validation:** Verify the implementation meets every condition in the acceptance criteria.
2. **Entropy testing:** Attack inputs, edge cases, error states, and latency paths — the unwritten seams where implementations break.
3. **If defects found:** Reject the work. Comment on the GitHub issue with the defect report (defect description, reproduction steps, expected vs actual, environmental context). Move the issue back to **In Progress**. Escalate to the user.
4. **If passed:** Comment on the issue confirming QA approval. Move the issue to **Done**.

**Completion gate:** The issue is either rejected with documented defects and returned for fixes, or approved and marked done. The user is notified of the outcome.
