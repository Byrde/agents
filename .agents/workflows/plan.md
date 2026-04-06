# Workflow: Plan

Plan and decompose a user request into fully spec'd, GitHub-tracked work items, then enrich each with architectural guidance.

## Jobs

This workflow composes the following jobs, in order:

1. **Technical Planner** — `jobs/plan.md`
2. **Systems Architect** — `jobs/architect.md`

## Dependencies

### Required Files

These files **must** exist before this workflow can execute. If any are missing, **fail immediately** and tell the user what needs to be created.

| File | Purpose |
| --- | --- |
| `tools/github.md` | GitHub account, repository, and project board configuration. |

### Discovered Context

The following context is **not** pre-configured. It must be elicited from the user (or inferred from the codebase) at the start of the workflow. Do not assume — ask.

- **Tech stack:** Languages, frameworks, databases, and key libraries in use.
- **Conventions:** Branch naming, label taxonomy, issue templates, PR process, or any team-specific norms.
- **Non-negotiables:** Hard constraints the plan must respect (e.g. compliance requirements, performance budgets, dependency policies, compatibility guarantees).

## Steps

### Step 1 — Planning (same context)

**Job:** Technical Planner (`jobs/plan.md`)
**Runs in:** The current conversation context (interactive, collaborative).

**Procedure:**

1. **Validate dependencies:** Confirm `tools/github.md` and `practices/development.md` exist and are populated. Fail if not.
2. **Gather context:** Elicit the discovered context (tech stack, conventions, non-negotiables) from the user. Keep it conversational — ask only what is needed for the scope at hand, not an exhaustive questionnaire.
3. Receive the user's raw request (feature idea, bug report, initiative, or vague direction).
4. Classify the request into a scope bucket (epic, feature, or bugfix) per the job definition. If ambiguous, make the call explicit with the user before proceeding.
5. Decompose the request into GitHub-tracked work:
   - **Epic** — create a milestone, then break it into feature issues and stories.
   - **Feature** — create a single issue (or tight set) with acceptance criteria, linked to an existing milestone if applicable.
   - **Bugfix** — create a bug issue with repro steps, expected vs actual, and scope limited to the fix.
6. Every issue must satisfy the Ironclad Rule from the job spec: acceptance criteria, t-shirt size, priority, and a dependencies section.
7. Present the full breakdown to the user for review. Iterate until the user confirms the plan.

**Completion gate:** The user has explicitly approved the breakdown — all issues are created on the GitHub project board and correctly linked/milestoned.

### Step 2 — Architectural Enrichment (MUST RUN AS SUBAGENT)

**Job:** Systems Architect (`jobs/architect.md`)
**Runs in:** A sub-agent (isolated context, launched after Step 1 completes).

**Input to sub-agent:**
- The list of GitHub issues created in Step 1 (numbers and repository).
- The contents of `tools/github.md` and `practices/development.md`.
- Any discovered context (tech stack, conventions, non-negotiables) gathered in Step 1.

**Procedure:**

1. For each issue created in Step 1, the architect evaluates whether it has meaningful architectural surface — structural decisions, integration points, data modeling, infrastructure concerns, or build-vs-buy implications.
2. **Skip** issues that are purely cosmetic, copy-only, or have no architectural bearing.
3. For each architecturally relevant issue, leave a comment on the GitHub issue containing:
   - A concise architectural assessment: key decisions, constraints, and risks for that slice.
   - Mermaid diagram(s) where a visual adds clarity (system boundaries, sequence flows, component relationships) — only when strategically valuable, not for the sake of it.
   - Recommended approach and any trade-offs the implementer should be aware of.
   - Flags for anything that needs further discussion or decision before implementation can start.
4. If the architect identifies cross-cutting concerns, missing issues, or dependency gaps across the breakdown, surface these as a summary comment on the milestone (for epics) or as a reply to the user.

**Completion gate:** Every architecturally relevant issue has been reviewed and commented on. The user is notified that the plan is fully enriched and ready for execution.