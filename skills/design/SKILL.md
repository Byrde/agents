---
name: design
description: "Use it before you build or change a screen, flow or component. Frames the problem with the user, sketches two options, records the choice, and delivers what a developer needs to build it. Reuses existing components and tokens before it adds new ones."
category: practice
interactive: true
---

# Design

Design a screen, flow or component with the user. Scale to the work: a button is three
sentences, an onboarding flow is three rounds of conversation.

## Method

1. **Frame.** Say what you will design, who it is for, and what constrains it. Get that
   confirmed.
2. **Sketch two options.** Use the cheapest fidelity that answers the question: an ASCII
   layout, a written spec, or visuals when the decision is visual. Give the trade-offs.
3. **Decide and deliver.** Name what the user chose, what they rejected, and what is
   deferred. Deliver what a developer needs to build it. When a spec is in play, write
   it to `design.md` in the feature directory. Comment on the work item with the
   summary when one is in play.

Cover the unhappy paths: empty, loading and error. Cover the interactive states where
they apply: hover, disabled and focus.

## Reuse before you add

- **Audit first.** Read the design tokens and the components that exist.
- **Compose what exists.** Use no detached instance and no hardcoded value.
- **Extend on purpose.** Propose a new token or component with a reason, and get the
  user's agreement. Then add it, name its states and variants, and publish the library.
- **Take sizes from the build.** When you align to existing code, read the real sizes and
  spacing in the implementation.
- **Name the code component.** When the project keeps a `figma-code-map.json`, name the
  mapped code component in what you deliver.

A controversial extension of the design system is an open item for the user. So is a
decision that belongs to someone outside the conversation.

## Tools

Read the skill list. Never assume a tool skill is absent.

- **The Figma tool skill** — invoke it before you create or edit anything in the design
  file. Never operate the design file through a raw API call.
- **The tracker's tool skill** — invoke it before you comment on a work item.

Without design tooling, deliver sketches and a written spec in the conversation, and say
so.
