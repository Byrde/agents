# Workflow: Design UI

Collaborate with the user to apply visual design to a scoped component, building from existing wireframes and the shared design system.

## Jobs

1. **UI Designer** — `.agents/jobs/design-ui.md`

## Tooling

**Figma is required for this workflow.** All UI artifacts — tokens, components, and high-fidelity screens — are created and managed in Figma using the configuration and conventions defined in `.agents/tools/figma.md`. The Figma MCP server is the sole interface for all Figma operations.

**GitHub is optional.** When a GitHub issue or milestone is provided, it defines the scope and anchors the work. When no issue is provided, the work is treated as ad-hoc and scoped conversationally.

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

The following context is **not** pre-configured. It must be elicited from the user (or inferred from wireframes/issue) at the start of the workflow. Do not assume — ask.

- **What is being designed:** The specific component (or bounded composite) in scope for this session — its name, purpose, and where it lives in the product.
- **Structure and hierarchy:** The layout intent for this component — typically from an approved wireframe on the Wireframes page of the feature file, a written spec, or a direct user description.
- **Constraints:** Platform (web, mobile, etc.), accessibility expectations, brand or product constraints, and any technical limits.
- **Design system baseline:** Whether the project already has established tokens in the Design System file. If yes, the session follows them. If no, establishing a modest initial token set is part of this session's work.

When a feature file with approved wireframes exists, it is the primary input. Read the Wireframes page and its annotations first, then fill gaps conversationally.

## Steps

### Step 1 — Scope & Orientation (same context)

**Job:** UI Designer (`.agents/jobs/design-ui.md`)
**Runs in:** The current conversation context (interactive, collaborative).

**Procedure:**

1. **Validate dependencies:** Confirm `.agents/tools/figma.md` exists and is populated. Run the Figma MCP preflight check (server health, context validation, design system file validation, design system structure validation). Fail if any check does not pass.
2. **Determine mode:** Ask the user whether this work is scoped to a GitHub issue or ad-hoc. If a GitHub issue is provided, validate `.agents/tools/github.md` and read the issue for existing context.
3. **Identify the component:** Name the single component (or bounded composite) in scope for this session. Confirm with the user. Do not proceed with an open-ended "whole screen" scope.
4. **Locate the wireframe:** Find the approved wireframe that contains this component on the Wireframes page of the feature file. Read the annotations for layout intent, interaction notes, and accessibility expectations. If no wireframe exists, gather equivalent structural input from the user before proceeding.
5. **Audit the design system:** Query the Design System file via the Figma MCP server to understand what tokens, variables, and components already exist. Identify what can be reused for this component and what gaps exist.
6. **Present the plan:** Summarize for the user: what component is being designed, what wireframe it's based on, what existing tokens/components will be reused, and what new elements (if any) may need to be created. **Wait for explicit user confirmation** before designing.

**Completion gate:** The user has confirmed the component scope, structural input, and design system baseline.

### Step 2 — Design System Extension (same context, if needed)

**Job:** UI Designer (`.agents/jobs/design-ui.md`)
**Runs in:** The current conversation context (interactive).

This step runs **only if** the audit in Step 1 identified gaps in the design system that must be filled before the component can be designed. If the existing tokens and components are sufficient, skip to Step 3.

**Procedure:**

1. **Propose token/component additions:** Present the specific additions needed — new color roles, spacing values, type styles, or atomic components. Explain why each addition is necessary and why the existing set is insufficient. Follow the DRY principle: propose only what this component genuinely requires.
2. **Get user approval:** Do not modify the Design System file without explicit user buy-in on the proposed additions.
3. **Implement in the Design System file:**
   - Add new tokens as Figma Variables in the appropriate collection (Primitives, Semantics, or Component-specific), following the naming conventions in `.agents/tools/figma.md`.
   - Add new atomic components on the appropriate page (Atoms, Molecules, or Organisms) with all required states.
   - Update the Foundations page if new token categories or values were added.
4. **Publish the library:** Re-publish the Design System library with a descriptive update note so feature files receive the changes.

**Completion gate:** The Design System file has been updated and published with the necessary additions. The user has approved all changes.

### Step 3 — Component Design (same context)

**Job:** UI Designer (`.agents/jobs/design-ui.md`)
**Runs in:** The current conversation context (interactive, collaborative).

**Procedure:**

1. **Generate options:** On the **Visual Design** page of the feature file, create multiple high-quality design options for the scoped component. Each option must:
   - Use components and tokens from the Design System library (no detached instances, no hardcoded values).
   - Respect the layout intent and hierarchy from the wireframe.
   - Honor the accessibility expectations from the wireframe annotations.
2. **Design all states:** For every interactive element in the component, explicitly design all interactive states: Default, Hover, Active/Pressed, Disabled, Focused, and Error (where applicable).
3. **Define variants:** Use Figma's component properties to define meaningful variants (size, style, state) so developers can switch between them cleanly.
4. **Present to user:** Walk through the options with the user. Explain the rationale for each option and how it relates to the wireframe intent. Gather feedback.
5. **Iterate:** Refine based on user feedback. Converge on a single approved direction. Do not settle prematurely — exhaust the meaningful option space for this component.

**Completion gate:** The user has approved a final component design with all states and variants.

### Step 4 — Finalization & Handoff (same context)

**Job:** UI Designer (`.agents/jobs/design-ui.md`)
**Runs in:** The current conversation context (interactive).

**Procedure:**

1. **Promote to Design System (if applicable):** If the approved component is a reusable element (not feature-specific), add it to the appropriate page in the Design System file (Atoms, Molecules, or Organisms). Publish the library update.
2. **Prepare for development:** Move the approved, final screens to the **Ready for Development** page of the feature file. Mark them with Figma's "Ready for development" section status.
3. **Clean up:** Move rejected options and explorations to the **Archive / Exploration** page with brief annotations explaining why they were not selected.
4. **Update Cover:** Update the feature file status to reflect progress (e.g. "In Development" if all components for the feature are designed).
5. **Deliver based on mode:**
   - **GitHub issue in scope:** Comment on the GitHub issue with a summary of the visual design decisions, a link to the Ready for Development page in the Figma feature file, and any implementation notes (token references, component variant usage, interaction details not captured in the static design).
   - **Ad-hoc:** Deliver the summary directly in the conversation, including the Figma file link and implementation notes.
6. **Surface open items:** Flag anything that needs further discussion — interaction details that require prototyping, responsive behavior questions, or edge cases deferred during this session.

**Completion gate:** The component design is finalized and delivered. Approved screens are on the Ready for Development page. The Design System is updated if applicable. Open items are flagged. The user is notified that visual design for this component is locked and ready for implementation.
