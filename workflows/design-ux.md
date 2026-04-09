# Workflow: Design UX

Collaborate with the user to define, map, and wireframe the user experience for a feature or epic.

## Jobs

1. **UX Designer** — `.agents/jobs/design-ux.md`

## Tooling

**Figma is required for this workflow.** All UX artifacts — user flows, wireframes, and annotations — are created and managed in Figma using the configuration and conventions defined in `.agents/tools/figma.md`. The Figma MCP server is the sole interface for all Figma operations.

**GitHub is optional.** When a GitHub issue or milestone is provided, it defines the scope and anchors the work — the corresponding Figma feature file's Cover page links back to the issue. When no issue is provided, the work is treated as ad-hoc and scoped conversationally.

## Dependencies

### Required Files

These files **must** exist and be fully populated before this workflow can execute. If any are missing or incomplete, **fail immediately** and tell the user what needs to be created.

| File | Purpose |
| --- | --- |
| `.agents/tools/figma.md` | Figma team, project, design system file, and conventions. |

### Optional Files

| File | Required | Purpose |
| --- | --- | --- |
| `.agents/tools/github.md` | **Only when a GitHub issue is in scope.** | GitHub account, repository, project board configuration, and conventions. |

### Discovered Context

The following context is **not** pre-configured. It must be elicited from the user (or inferred from the codebase/issue) at the start of the workflow. Do not assume — ask.

- **Problem and audience:** What problem is being solved, for whom, and what "done" looks like.
- **Scope of the UX slice:** Which flow, feature, or epic is in scope — not an open-ended "whole product" unless explicitly bounded.
- **Constraints:** Platform(s), regulatory or organizational requirements, timeline, and any non-negotiable technical or business limits.
- **Context:** Existing product map, live flows, or legacy behavior when iterating; links or references to prior decisions if the work continues earlier UX.

When a GitHub issue is provided, much of this context may already be captured in the issue body and comments. Read the issue body **and all comments** first — comments are where architectural decisions, design notes, and prior discussion live. Then fill gaps conversationally.

## Steps

### Step 1 — Discovery & Framing (same context)

**Job:** UX Designer (`.agents/jobs/design-ux.md`)
**Runs in:** The current conversation context (interactive, collaborative).

**Procedure:**

1. **Validate dependencies:** Confirm `.agents/tools/figma.md` exists and is populated. Run the Figma MCP preflight check (server health, context validation, design system file validation). Fail if any check does not pass.
2. **Determine mode:** Ask the user whether this work is scoped to a GitHub issue or ad-hoc. If a GitHub issue is provided, validate `.agents/tools/github.md` and read the issue body **and all comments** for existing context (acceptance criteria, architectural decisions, design notes, prior discussion).
3. **Gather context:** Elicit the discovered context listed above. If a GitHub issue is in scope, use it as the starting point and only ask about gaps. Keep it conversational.
4. **Frame the problem:** Summarize the problem space — who the product serves, the job to be done, success criteria, and constraints. Get explicit user confirmation that the framing is correct before proceeding.

**Completion gate:** The user has confirmed the problem framing and scope.

### Step 2 — Feature File Setup (same context)

**Job:** UX Designer (`.agents/jobs/design-ux.md`)
**Runs in:** The current conversation context (interactive).

**Procedure:**

1. **Locate or create the feature file:** Check if a Figma feature file already exists for this epic or feature in the project specified in `.agents/tools/figma.md`.
   - **If it exists:** Open it and verify the required page structure (Cover, User Flows, Wireframes, Visual Design, Prototypes, Ready for Development, Archive / Exploration). Create any missing pages.
   - **If it does not exist:** Create a new Figma file in the project with the feature/epic name. Set up all required pages per the feature file structure in `.agents/tools/figma.md`.
2. **Set up the Cover page:** Add the feature name, current status (Draft), owner, and a link to the GitHub issue or milestone when applicable.
3. **Confirm with user:** Share the file link and confirm the workspace is ready.

**Completion gate:** The feature file exists with the correct page structure, and the user has confirmed.

### Step 3 — Flow Mapping (same context)

**Job:** UX Designer (`.agents/jobs/design-ux.md`)
**Runs in:** The current conversation context (interactive, collaborative).

**Procedure:**

1. **Map the user flow:** On the **User Flows** page of the feature file, create flow diagrams that capture:
   - All entry points into the feature
   - Every decision node and branch
   - Happy path(s) through to completion
   - Unhappy paths: error recovery, abandonment, edge cases
   - Exit points (success, failure, redirect)
2. **Stress-test for cognitive load:** Walk through each path with the user. Identify unnecessary steps, confusing branches, or places where the user might get lost. Simplify.
3. **Iterate:** Refine based on user feedback. Do not proceed to wireframes until the user explicitly approves the flow.

**Completion gate:** The user has approved the user flow(s). All paths — happy and unhappy — are mapped.

### Step 4 — Wireframing (same context)

**Job:** UX Designer (`.agents/jobs/design-ux.md`)
**Runs in:** The current conversation context (interactive, collaborative).

**Procedure:**

1. **Create wireframes:** On the **Wireframes** page of the feature file, produce low/mid-fidelity screens for every state in the approved flow:
   - Follow the fidelity rules: grayscale, system fonts, structure-focused.
   - Name frames sequentially and descriptively (e.g. `01_Signup_Start`, `02_Signup_Email`, `03_Signup_Error`).
   - Include unhappy path screens: empty states, error states, loading states.
2. **Annotate intent:** For every wireframe, add annotations explaining:
   - *Why* the layout is structured this way.
   - Accessibility expectations: focus order, semantic structure, screen reader announcements.
   - Interaction notes: what happens on tap/click, transitions, conditional visibility.
   - Friction points that were deliberately removed and why.
3. **Walk through with user:** Present the wireframes in flow order. Gather feedback on hierarchy, layout, and interaction intent — not visual styling.
4. **Iterate:** Refine based on user feedback until the wireframes are approved.

**Completion gate:** The user has approved the wireframes. All screens, states, and annotations are complete on the Wireframes page.

### Step 5 — Handoff & Lock (same context)

**Job:** UX Designer (`.agents/jobs/design-ux.md`)
**Runs in:** The current conversation context (interactive).

**Procedure:**

1. **Final review:** Confirm with the user that the User Flows page and Wireframes page together represent the complete, approved UX for this scope.
2. **Update Cover:** Change the feature file status to "In Review" or "Approved" as appropriate.
3. **Deliver based on mode:**
   - **GitHub issue in scope:** Post a **`## UX Design`** comment on the GitHub issue containing:
     - **Decisions:** A summary of the UX decisions made during this session — user flows chosen, structural rationale, and key trade-offs.
     - **Figma link:** A direct link to the Figma feature file (User Flows and Wireframes pages).
     - **Screen mapping:** Which wireframe screens map to which acceptance criteria.
     - **Open items:** Any unresolved questions, deferred decisions, or flags for visual design and implementation.
   - **Ad-hoc:** Deliver the same summary directly in the conversation, including the Figma file link.
4. **Surface open items:** Flag anything that needs further discussion before visual design or implementation can proceed — ambiguous interactions, unresolved edge cases, or decisions deferred to visual design.

**Completion gate:** UX artifacts are complete and delivered. The feature file is updated. Open items are explicitly flagged. The user is notified that UX work is locked and ready for visual design.
