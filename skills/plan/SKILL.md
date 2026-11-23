---
name: plan
description: "Use it before you create, split, restructure or re-scope work items: an issue, an epic, acceptance criteria. Turns a request or an approved design into tracked work items with acceptance criteria, size, priority and dependencies, through the project's tracker. Without a tracker, keeps the record in `project.md`."
category: practice
interactive: true
---

# Plan

Turn a request into work items the team can pick up. This is a conversation with the
user. Confirm the intent before you slice, and confirm the breakdown before you create
anything.

## Shape

Match the slices to the work. A one-line fix is one item. Decide a borderline case with
the user, and record the decision on the work item.

- **Epic** — several user journeys or systems, or a direction more than an outcome.
  Create a container (a milestone or its equivalent) plus the slices.
- **Feature** — one shippable slice with tight acceptance criteria. Usually one item.
- **Bugfix** — a failure that reproduces, with expected against actual. The scope is the
  fix.

## Each work item carries

- **Acceptance criteria**, one testable statement per line, in `Given / When / Then`
  form. The `technical-writing` rule sets the level.
- **Size** (XS, S, M, L, XL) and **priority**, in the tracker's structured fields.
- **Dependencies**, as explicit links to the blockers.
- **A structural note**, only when the item touches a module boundary, a data model or a
  build-versus-buy decision: the decision, the constraints and the open questions.

A decision that belongs to someone outside the conversation is an open item. Never guess
it.

## Tracker

Invoke the tracker's tool skill (`github-projects` or `jira`) before you create an item,
set a field, or place anything on a board. Read the skill list. Never assume it is
absent.

## Without a tracker: project.md

Keep a `project.md` at the root of the repository only when the work needs a record:
it has more than one slice, it continues in a later session, or the user asks for one.
When a work item tracks the work, the work item is the record. Do not keep both.

```markdown
# <Project name>

## Intent
<What the user asked for and why, in two or three sentences. Confirmed: yes/no.>

## Scope
Shape: feature | bugfix | small epic. In: <…>. Out: <…>.

## Slices
### 1. <Imperative title> — <todo | doing | done>
- Size: XS | S | M | L. Priority: <…>. Depends on: <slice or none>.
- Acceptance criteria:
  - Given <…>, when <…>, then <…>.
- Notes: <structural surface, risks>

## Decisions
- <Date>: <decision>. Rejected: <option>, because <reason>.

## Open questions
- <Question> — owner: <who decides>.

## Log
- <Date>: <what shipped, pull request link>.
```

Update it in the same step as the work it records. Use absolute dates.
