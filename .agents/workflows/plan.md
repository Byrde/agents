# Workflow: Plan

Plan and decompose a user request into fully spec'd, GitHub-tracked work items, then enrich each with architectural guidance.

## Jobs

This workflow composes the following jobs, in order:

1. **Technical Planner** — `jobs/plan.md`
2. **Systems Architect** — `jobs/architect.md`

## Context

<!-- PROJECT-SPECIFIC: Replace or populate this section per-project. -->
<!-- This is the injection point for constraints, conventions, and project knowledge. -->

**Repository:** <!-- e.g. byrde/my-app -->
**Project board:** <!-- e.g. My App -->
**Tech stack:** <!-- e.g. Kotlin, Ktor, PostgreSQL, React, Tailwind -->
**Architectural baseline:** <!-- e.g. Lite DDD modular monolith, event-driven between bounded contexts -->
**Conventions:** <!-- e.g. branch naming, label taxonomy, issue templates, PR process -->
**Non-negotiables:** <!-- e.g. must support multi-tenancy, HIPAA compliance, no new runtime deps without approval -->

## Steps

### Step 1 — Planning (same context)

**Job:** Technical Planner (`jobs/plan.md`)
**Runs in:** The current conversation context (interactive, collaborative).

**Procedure:**

1. Receive the user's raw request (feature idea, bug report, initiative, or vague direction).
2. Classify the request into a scope bucket (epic, feature, or bugfix) per the job definition. If ambiguous, make the call explicit with the user before proceeding.
3. Decompose the request into GitHub-tracked work:
   - **Epic** — create a milestone, then break it into feature issues and stories.
   - **Feature** — create a single issue (or tight set) with acceptance criteria, linked to an existing milestone if applicable.
   - **Bugfix** — create a bug issue with repro steps, expected vs actual, and scope limited to the fix.
4. Every issue must satisfy the Ironclad Rule from the job spec: acceptance criteria, t-shirt size, priority, and a dependencies section.
5. Present the full breakdown to the user for review. Iterate until the user confirms the plan.

**Completion gate:** The user has explicitly approved the breakdown — all issues are created on the GitHub project board and correctly linked/milestoned.

### Step 2 — Architectural Enrichment (sub-agent)

**Job:** Systems Architect (`jobs/architect.md`)
**Runs in:** A sub-agent (isolated context, launched after Step 1 completes).

**Input to sub-agent:**
- The list of GitHub issues created in Step 1 (numbers and repository).
- The project context from the Context section above.

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

