---
name: plan
description: "**MUST be invoked** before you create, split, restructure or re-scope a work item. NEVER write an issue, epic or acceptance criteria without loading this first. Skipping it leaves work untracked, unsized and off the board, because this skill is what consults the tracker. Decompose a request — vague or detailed — into trackable work, sized and prioritised at the right granularity. Surfaces dependencies and architectural concerns alongside the breakdown. Adapts to the work: a small fix becomes one item, an epic becomes a container plus its slices."
category: practice
---

# Plan

Turn a raw request into a set of tracked work items the team can actually pick up.

## Mindset

- **Understand intent before slicing.** Size, risk, and dependencies inform the bucket — don't classify on instinct.
- **Right-sized granularity.** Don't decompose a one-line fix into three issues. Don't pack an epic into a single ticket. Match the slices to the work.
- **Explicit dependencies beat implicit ones.** If item A blocks item B, say so on the work items.
- **Architectural surface gets flagged early.** When a slice has structural implications, surface them on the work item. Integration points, data modeling and build-vs-buy calls ambush implementation otherwise.
- **Make ambiguity visible.** Name an edge case between buckets, such as "a small epic or a large feature". Decide it *with* the user, never for them.

## Inputs

- **The request** — feature idea, bug report, initiative, or vague direction. Whatever shape it arrives in.
- **Tech stack** — languages, frameworks, databases, key libraries.
- **Non-negotiables** — compliance, performance budgets, dependency policies, compatibility guarantees.
- **Conventions** — team norms beyond what's already captured in installed tool skills.

Elicit only what the scope at hand needs. Keep it conversational.

## Procedure

1. **Frame the request.** Restate what the user is asking for. Confirm the intent before slicing.
2. **Pick a scope shape.** Default buckets:
   - **Epic** — a multi-slice initiative that needs a container. Signals: multiple user journeys, several systems touched, or "direction" rather than "outcome." Create a container (milestone or equivalent) plus the slices.
   - **Feature** — a concrete, shippable slice with tight acceptance criteria. Usually one work item, occasionally a small set.
   - **Bugfix** — corrective work with a reproducible failure, expected-vs-actual, and scope limited to the fix.

   If the request straddles buckets, decide explicitly with the user and record the call on the work item.
3. **Decompose.** Break the work into items at the granularity that matches the bucket. Don't over-fragment. Don't under-specify.
4. **Spec each item.** Every work item should include:
   - Acceptance criteria — the conditions that make it done.
   - Size (XS/S/M/L/XL) and priority — set via the project's structured fields when a tracker is installed. Set them in conversation otherwise.
   - Dependencies — link blockers and prerequisites explicitly.
5. **Flag architectural surface.** For items with meaningful structural implications, attach a short architectural note — key decisions, constraints, recommended approach, open questions. Skip cosmetic or copy-only items. Mermaid diagrams only when a picture earns its keep.
6. **Present the breakdown.** Walk through the plan with the user. Iterate until they confirm.

## When to halt

- The request is too vague to slice — go back to framing.
- A decision needs a stakeholder who isn't in the conversation — log it as an open item rather than guessing.
- The architectural surface is bigger than expected — pause planning, suggest running `architect` first to nail the structure, then come back.

## Composition

**Check what is installed. Never assume a tool skill is absent.** A tool skill is inert
until you invoke it. A rule is already in context. See `global.md` → Tool skills for
which is which.

- **`github-projects`** — invoke it before you create a work item, set a field, or place
  anything on a board. It carries conventions you will otherwise get wrong: milestones
  are epics, and PR-merge automation owns the transition to Done.

Only when no tracker is available: deliver the breakdown in the conversation as a
structured list, and say that is what you are doing.

