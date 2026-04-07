# Workflow: Develop

Collaborate with the user to understand requirements, then implement them as tested, production-quality code.

## Jobs

1. **Software Developer** — `.agents/jobs/develop.md`

## Tooling

**GitHub is optional in this workflow.** When a GitHub issue is provided, it defines the scope and serves as the record of work — branch creation, issue state transitions, pull requests, and implementation notes all follow the conventions in `.agents/tools/github.md`.

When no issue is provided, the work is treated as ad-hoc. Requirements are established conversationally and all output (code, tests, implementation notes) is delivered directly in the conversation.

## Dependencies

### Required Files

| File | Required | Purpose |
| --- | --- | --- |
| `.agents/tools/github.md` | **Only when a GitHub issue is in scope.** | GitHub account, repository, project board configuration, and conventions. |

If a GitHub issue is in scope and `.agents/tools/github.md` is missing or incomplete, **fail immediately** and tell the user what needs to be created.

### Discovered Context

The following context is **not** pre-configured. It must be elicited from the user (or inferred from the codebase/issue) at the start of the workflow. Do not assume — ask.

- **What is being built:** The feature, fix, or change — its purpose, boundaries, and why development is needed now.
- **Acceptance criteria:** The explicit conditions that must be true when the work is done. When a GitHub issue is in scope, these should already exist in the issue body.
- **Constraints:** Technical limits, compatibility requirements, performance expectations, or anything that bounds the implementation approach.

When a GitHub issue is provided, much of this context may already be captured in the issue body and architectural comments. Read the issue first, then fill gaps conversationally.

## Steps

### Step 1 — Review & Alignment (same context)

**Job:** Software Developer (`.agents/jobs/develop.md`)
**Runs in:** The current conversation context (interactive, collaborative).

**Procedure:**

1. **Determine mode:** Ask the user whether this work is scoped to a GitHub issue or ad-hoc. If a GitHub issue is provided, validate `.agents/tools/github.md` and read the issue for existing context (description, acceptance criteria, architectural comments).
2. **Gather context:** Elicit the discovered context listed above. If a GitHub issue is in scope, use it as the starting point and only ask about gaps. Keep it conversational.
3. **Verify current state:** If a GitHub issue is in scope, check that it is not already implemented. If partially implemented, map what remains.
4. **Extract and verify requirements:** List implicit assumptions or ambiguities. Resolve with the user before proceeding. If gaps require a spec update, halt and clarify before moving forward.
5. **Flag to proceed:** Present the developer's understanding of the work — what will be built, what the tests will cover, and any decisions made. **Wait for explicit user confirmation** before moving to implementation.

**Completion gate:** The user has confirmed the developer's understanding and given the go-ahead.

### Step 2 — Implementation (same context)

**Job:** Software Developer (`.agents/jobs/develop.md`)
**Runs in:** The current conversation context (interactive).

**Procedure:**

1. **TDD loop:** Write contract tests encoding the acceptance criteria, implement to green, refactor within scope.
2. **If blocked:** Stop implementation. Flag the gap to the user and wait for resolution before continuing.
3. **Deliver based on mode:**
   - **GitHub issue in scope:** Create branch following `.agents/tools/github.md` conventions. Move issue to **In Progress** at start. Open PR following the format in `.agents/tools/github.md`. Move issue to **Ready to Test**. Comment on the issue with what was done, the PR link, and anything a reviewer should know.
   - **Ad-hoc:** Deliver all code, tests, and implementation notes directly in the conversation.

**Completion gate:** Implementation is complete and delivered — either as a PR with issue updated, or as code in the conversation. The user is notified and can review.
