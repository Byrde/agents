---
name: design
description: Design something — a feature, a flow, a screen, a component, a
  single interaction. Adapts to scope and fidelity - small problems get small
  procedures, big problems get more conversation. Reuses the project's design
  system before extending it. Pairs with figma-design-system, figma-feature-files,
  and figma-use when those skills are installed.
category: practice
---

# Design

Help a user design something — at whatever scope and fidelity the work in front of you calls for.

## Mindset

- **Friction is a failure of empathy.** Every interaction is a conversation between a human and a machine; design so the machine acts as a gracious, anticipating host.
- **The medium serves the message.** Wireframes, mocks, sketches, prototypes, written specs — pick the fidelity that gets the right feedback for *this* decision. Don't moralise about which comes first.
- **Diverge before converging.** Refuse to settle on the first good idea. Generate multiple credible options, then pick.
- **Unhappy paths are explicit.** Empty, loading, error, recovery — they're part of the design, not afterthoughts.
- **All interactive states are explicit.** Default, hover, active/pressed, disabled, focused, error (where applicable) — when the design involves interactive elements, name every state.
- **DRY by default.** Reuse what's in the design system before adding to it. Extending the system is sometimes the right call — but it's a decision, not a reflex.
- **Annotate intent.** *Why* a layout is structured this way, accessibility expectations (focus order, semantics, announcements), interaction notes. Capture what isn't self-evident from the visual.

## Inputs

Elicit what's needed for the scope at hand. A small task ("design this button") needs less than a big one ("design the onboarding flow").

- **What is being designed** — feature, flow, screen, component, single decision. Bound the scope explicitly.
- **Audience and problem** — who this is for, what they're trying to do, what's in the way.
- **Constraints** — platform, accessibility expectations, brand/product limits, performance, technical limits.
- **Context** — existing flows, prior decisions, related screens or components. If a work item is referenced, read it and its comments.
- **Design system baseline** — what reusable components, typography, colors, icons, logos already exist in the project's design system. If a `figma-design-system` skill is installed, **read design tokens** and **read design components** to audit. If none exists yet, establishing a modest baseline is part of the work.

## Procedure (five moves, scaled to the work)

1. **Understand.** Frame the problem in your own words and reflect it back. Audience, job to be done, success criteria, constraints. Get the framing confirmed before designing.
2. **Explore.** Generate options. For flows: alternative paths and entry points. For components: alternative shapes, layouts, interaction models. Push past the first viable idea. Walk the options with the user — explain trade-offs, gather feedback.
3. **Decide.** Converge on a direction. Name explicitly what's been chosen, what's been rejected (and why), and what's been deferred for a future pass. No silent commitments.
4. **Make it concrete.** Produce the artifact that lets a developer build the decision. Pick fidelity by what the decision needs:
   - **Low/mid-fidelity (wireframes, sketches, ASCII layouts):** when the conversation is about structure, hierarchy, flow, or behavior — pixels would be a distraction.
   - **High-fidelity (visual design):** when the conversation is about visual treatment, brand expression, or final-look decisions. Use the project's design system — no detached instances, no hardcoded values. Design all relevant states.
   - **Written spec or annotated reference:** when the situation doesn't need new visuals (e.g., a small variation of an existing component).
   - **Prototype:** when interaction timing, transitions, or feel is the point of the decision.

   Whatever the fidelity, annotate the *why* — layout intent, accessibility, interaction notes, friction deliberately removed.
5. **Hand off.** Make sure the receiver has what they need. Summarise the decisions made, key trade-offs, the location of the artifact, screen-to-criteria mapping (if there's a work item), and any open items flagged for implementation. If a work item is in play, **comment on the work item** with the summary. Otherwise deliver it in the conversation.

The five moves apply at any scope. A "design this button" session might be five sentences. A "design the onboarding flow" session might be five conversation rounds. The shape is the same.

## Working with the design system

- **Audit first.** Before designing, see what's already in the design system — components, typography, colors, spacing, icons, logos.
- **Reuse before invention.** If an existing component or token fits, use it. Compose existing pieces if you can.
- **Extend with intent.** When the scoped work genuinely needs something new, propose the addition with rationale, get user buy-in, then **add design token** / **add design component** through the design-system tool, and **publish the design library**.
- **No detached instances, no hardcoded values.** Visual design pulls from the published library.

## When to halt

- The problem framing is fuzzy — go back to understanding; don't design against guesses.
- The scope keeps expanding mid-session — name what's in scope, name what's been deferred, finish the current scope first.
- A decision needs a stakeholder who isn't in the conversation — surface it as an open item, don't fake it.
- The design system would need a controversial extension — pause, surface the trade-off explicitly, get a deliberate decision.

## Composition

When Figma tool skills are installed:

- **`figma-design-system`** — audit and extend the design system through its operations (read/add tokens and components, publish library).
- **`figma-feature-files`** — create or open the feature workspace, mark finished frames ready for development.
- **`figma-use`** — drives the underlying plugin-API mechanics; the two skills above overlay on it.

When none of those skills are installed, deliver designs as descriptions, ASCII sketches, written specs, or links to external artifacts — whatever the situation supports.

When a project-management tool skill is installed (e.g., `github-projects`) and a work item is in scope, design decisions and handoff summaries are surfaced as a **comment on the work item**.
