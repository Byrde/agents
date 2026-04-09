# Workflow: Architect

Collaborate with the user to design, evaluate, or refine the structural architecture for a system or feature.

## Jobs

1. **Systems Architect** — `.agents/jobs/architect.md`

## Tooling

**GitHub is optional in this workflow.** When a GitHub issue is provided, it defines the scope and serves as the permanent record — all design decisions, diagrams, and architectural notes are posted as comments on that issue using the GitHub API and conventions in `.agents/tools/github.md`.

When no issue is provided, the work is treated as ad-hoc. All output (diagrams, decisions, trade-off analysis) is delivered directly in the conversation.

## Dependencies

### Required Files

| File | Required | Purpose |
| --- | --- | --- |
| `.agents/tools/github.md` | **Only when a GitHub issue is in scope.** | GitHub account, repository, project board configuration, and conventions. |

If a GitHub issue is in scope and `.agents/tools/github.md` is missing or incomplete, **fail immediately** and tell the user what needs to be created.

### Discovered Context

The following context is **not** pre-configured. It must be elicited from the user (or inferred from the codebase/issue) at the start of the workflow. Do not assume — ask.

- **What is being designed:** The system, feature, or integration under consideration — its purpose, boundaries, and why architectural input is needed now.
- **Scale and growth expectations:** Anticipated load, data volume, user base, and how these are expected to change.
- **Constraints:** Compliance, budget, team skill set, existing infrastructure, timeline, and any non-negotiable technology choices.
- **Tech stack:** Languages, frameworks, databases, and key libraries in use or under consideration.

When a GitHub issue is provided, much of this context may already be captured in the issue body and comments. Read the issue body **and all comments** first — comments are where architectural decisions, design notes, and prior discussion live. Then fill gaps conversationally.

## Steps

### Step 1 — Discovery & Alignment (same context)

**Job:** Systems Architect (`.agents/jobs/architect.md`)
**Runs in:** The current conversation context (interactive, collaborative).

**Procedure:**

1. **Determine mode:** Ask the user whether this work is scoped to a GitHub issue or ad-hoc. If a GitHub issue is provided, validate `.agents/tools/github.md` and read the issue body **and all comments** for existing context (architectural decisions, design notes, prior discussion).
2. **Gather context:** Elicit the discovered context listed above. If a GitHub issue is in scope, use it as the starting point and only ask about gaps. Keep it conversational.
3. **Reflect back:** Summarize the problem space, constraints, non-negotiables, and success criteria. Get explicit user confirmation that the framing is correct before designing anything.

**Completion gate:** The user has confirmed the problem framing and constraints.

### Step 2 — Design & Decision (same context)

**Job:** Systems Architect (`.agents/jobs/architect.md`)
**Runs in:** The current conversation context (interactive, collaborative).

**Procedure:**

1. **Frame the system:** Propose boundaries between services, data stores, clients, and integrations. Name the main components and how responsibility is split.
2. **Drive major decisions:** Lead build-vs-buy and technology-choice conversations with options, trade-offs, and a clear recommendation the user can accept or challenge.
3. **Validate direction:** Walk through failure modes, scaling paths, and migration stories so the user understands what they are committing to.
4. **Iterate:** Refine based on user feedback. Do not lock in until the user gives explicit buy-in on the direction.

**Completion gate:** The user has approved the architectural direction.

### Step 3 — Lock In (same context)

**Job:** Systems Architect (`.agents/jobs/architect.md`)
**Runs in:** The current conversation context (interactive, collaborative).

**Procedure:**

1. **Produce artifacts:** Turn agreed designs into Mermaid diagrams and concise written summaries — component responsibilities, integration contracts, key constraints, and any deferred decisions.
2. **Deliver based on mode:**
   - **GitHub issue in scope:** Post all artifacts (diagrams, summaries, decision records, flags) as comments on the issue. If cross-cutting concerns or dependency gaps are identified that affect other issues, surface those as separate comments on the relevant issues or milestone.
   - **Ad-hoc:** Deliver all artifacts directly in the conversation.
3. **Surface open items:** Flag anything that needs further discussion, a follow-up issue, or a decision from someone else before implementation can start.

**Completion gate:** All design artifacts are delivered (on the issue or in chat). Open items are explicitly flagged. The user is notified that the architecture is locked and ready to inform implementation.
