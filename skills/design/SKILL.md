---
name: design
description: Design a feature, flow, screen, or component. Frame the problem,
  sketch a couple of options, pick one, and write down what a developer needs to
  build it. Reuses existing components before adding new ones.
category: practice
---

# Design

Design something — at whatever scope the work calls for. Most sessions are short: a bit of framing, a sketch, a decision.

## Mindset

- **Reuse first.** Compose what already exists. A new component is a decision, not a reflex.
- **Sketch more than one option** before settling — but two is usually enough.
- **Unhappy paths are part of the design.** Empty, loading, error. Same for interactive states (hover, disabled, focus) where they apply.
- **Write down the why.** Layout intent, accessibility expectations, interaction notes — whatever isn't obvious from looking at it.

## Procedure

1. **Frame.** Say back what's being designed, who it's for, and what constrains it. Get that confirmed before designing. If a work item is referenced, read it and its comments.
2. **Sketch options.** A couple of credible directions at the cheapest fidelity that answers the question at hand — ASCII layout, written spec, or visuals when the decision is genuinely visual. Walk the trade-offs with the user.
3. **Decide and hand off.** Name what was chosen, what was rejected, and what's deferred. Deliver whatever a developer needs to build it. If a work item is in play, **comment on the work item** with the summary; otherwise deliver it in the conversation.

Scale to the work: "design this button" is three sentences, "design the onboarding flow" is three rounds of conversation.

## Reusable components

The payoff of a component library is that the second use is nearly free.

- **Audit before designing.** See what exists — components, spacing, colors, type. **Read design tokens** and **read design component** when a design system is available.
- **Reuse or compose** before inventing. No detached instances, no hardcoded values.
- **Extend deliberately.** When something genuinely new is needed, propose it with a rationale, get buy-in, then **add design token** / **add design component** and **publish the design library** so the next feature inherits it.
- **Name the states and variants** of anything added — that's what makes it a component rather than a one-off.
- **Derive from the build.** When aligning to existing code, take real sizes and spacing from the implementation, not from assumptions.

## When to halt

- Framing is fuzzy, or scope keeps growing — stop, name what's in and what's deferred, finish that first.
- A decision needs someone who isn't in the conversation, or the design system needs a controversial extension — surface it as an open item, don't decide it silently.

## Composition

Where a design-system or design-file tool is installed, the operations above route to it. Where none is, deliver designs as sketches, written specs, or links to external artifacts — whatever the situation supports.
