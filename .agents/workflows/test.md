# Workflow: Test

Validate an implementation against its requirements through rigorous, adversarial manual testing.

## Jobs

1. **QA Specialist** — `.agents/jobs/test.md`

## Tooling

**GitHub is optional in this workflow.** When a GitHub issue and/or PR is provided, they define the scope and serve as the record — all QA results, defect reports, and approvals are posted as comments on the issue using the conventions in `.agents/tools/github.md`.

When no issue is provided, the work is treated as ad-hoc. The test target and acceptance criteria are established conversationally and all output (pass/fail results, defect reports) is delivered directly in the conversation.

## Dependencies

### Required Files

| File | Required | Purpose |
| --- | --- | --- |
| `.agents/tools/github.md` | **Only when a GitHub issue is in scope.** | GitHub account, repository, project board configuration, and conventions. |

If a GitHub issue is in scope and `.agents/tools/github.md` is missing or incomplete, **fail immediately** and tell the user what needs to be created.

### Discovered Context

The following context is **not** pre-configured. It must be elicited from the user (or inferred from the codebase/issue) at the start of the workflow. Do not assume — ask.

- **Test target:** What is being validated — a feature, a fix, a specific behavior area, or a broader sweep.
- **Acceptance criteria:** The authoritative list of conditions for success. When a GitHub issue is in scope, these should already exist in the issue body.
- **How to exercise it:** Enough context to run the product or build under test — branch, commit, environment, feature flags, test accounts, or data setup.
- **Baseline expectations:** Known risks, areas of change, or "do not test" exclusions the user or spec calls out.

When a GitHub issue is provided, much of this context may already be captured in the issue body, implementation comments, and linked PRs. Read the issue first, then fill gaps conversationally.

## Steps

### Step 1 — Scope & Setup (same context)

**Job:** QA Specialist (`.agents/jobs/test.md`)
**Runs in:** The current conversation context (interactive, collaborative).

**Procedure:**

1. **Determine mode:** Ask the user whether this work is scoped to a GitHub issue or ad-hoc. If a GitHub issue is provided, validate `.agents/tools/github.md` and read the issue for existing context (acceptance criteria, implementation comments, linked PRs).
2. **Gather context:** Elicit the discovered context listed above. If a GitHub issue is in scope, use it as the starting point and only ask about gaps. Keep it conversational.
3. **Confirm test plan:** Present the QA specialist's understanding of what will be tested — the acceptance criteria that will be validated, the edge cases and unhappy paths that will be attacked, and how the build will be exercised. **Wait for explicit user confirmation** before starting the test pass.

**Completion gate:** The user has confirmed the test plan and scope.

### Step 2 — QA Validation (same context)

**Job:** QA Specialist (`.agents/jobs/test.md`)
**Runs in:** The current conversation context (interactive).

**Procedure:**

1. **Baseline validation:** Verify the implementation meets every condition in the acceptance criteria.
2. **Standards validation:** Verify the code adheres to the architectural and engineering standards in `.agents/practices/development.md` — dependency rules, folder structure, testing strategy, and separation of concerns. Deviations are defects.
3. **Entropy testing:** Attack inputs, edge cases, error states, and latency paths — the unwritten seams where implementations break.
3. **Deliver based on mode:**
   - **GitHub issue in scope — defects found:** Comment on the GitHub issue with the rejection: defect description, reproduction steps, expected vs actual, environmental context. Move the issue back to **In Progress**. If a defect warrants its own tracked item, open a new blocking bug issue per `.agents/tools/github.md` conventions.
   - **GitHub issue in scope — passed:** Comment on the issue confirming QA approval. Move the issue to **Done**.
   - **Ad-hoc — defects found:** Deliver the full defect report directly in the conversation: defect description, reproduction steps, expected vs actual, environmental context.
   - **Ad-hoc — passed:** Confirm approval directly in the conversation.

**Completion gate:** The implementation is either rejected with documented defects or approved. The user is notified of the outcome.
