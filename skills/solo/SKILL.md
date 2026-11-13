---
name: solo
description: "Run the whole loop — shape, plan, build, verify, ship — in one pass, as one persona, for work that fits in one pull request and adds no new boundary. Use it when the `global` rule's weight check picks `solo`, or when the user says solo, lite or keep it light. Replaces the separate plan, architect, develop and test practices for that work. Tracks the work in `project.md` only when the work needs a record. Escalates to the dedicated practices the moment the work outgrows it."
category: mode
---

# Solo

Do the work the dedicated practices would do, at the weight the change deserves. One
persona carries it from the request to the pull request.

## Mindset

- **Light is not careless.** Fewer stops, not fewer checks. Tests still come first, and
  the work is still verified before you call it done.
- **Ask once.** Collect every question that blocks you, ask them in one round, then
  work. Do not ask what the code or the request already answers.
- **Decide inline, write it down.** A structural choice gets one to three lines in the
  pull request body or in `project.md`, not a separate design session.
- **Know the exit.** The weight check in the `global` rule is your contract. When the
  work breaks it, escalate. Do not stretch `solo` to cover it.

## Inputs

- **The request**, and any work item it names. Read the work item and its comments.
- **The code around the change.** Read it before you decide anything.

## Procedure

1. **Frame.** Restate what you will build and how you will know it works, in two or three
   lines. List your assumptions. Ask the questions that block you, in one round. If none
   block you, say so and continue.
2. **Shape.** Choose the approach. Reuse what exists before you add anything. Follow the
   `development` rule. If the approach needs a structural decision, write it down in one
   to three lines, with the option you rejected.
3. **Slice.** If the work is one slice, continue. If it is two or more, list them with
   acceptance criteria, and do them in order. If the work needs a record, keep it in
   `project.md` (see below).
4. **Build each slice test-first.**
   - For new behavior, write a test that encodes the acceptance criteria. Then implement
     to green, then refactor within scope.
   - For something reported as broken, reproduce it with a test that fails first. Find
     the cause, not the symptom. Then fix it, and see the test pass.
5. **Verify.** Run the full relevant suite, the linter and the build. Check each
   acceptance criterion one by one. Then attack the change: try two or three inputs or
   paths it is likely to get wrong — empty, invalid, concurrent, the error path. Fix what
   you find, with a test.
6. **Ship.**
   - If the change goes through review, create the branch and open the pull request as
     the `github-source-control` rule says. The main checkout is fine for `solo` work
     when no other work is in progress there.
   - If a work item is in play, transition it and comment on it, as `develop` would.
   - Update `project.md`, if you keep one.
   - Report what changed, what you ran and its result, and what you did not check.

## project.md

Keep a `project.md` at the root of the repository the work is in, **only when the work
needs a record**:

- the work has more than one slice, or
- the work will continue in a later session, or
- the user asks for one.

When a work item already tracks the work, the work item is the record. Do not keep both.

Capture what `plan` would capture, in this shape:

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

## When to escalate

Stop and switch to the dedicated practices when any of these happens. Say which
condition broke. Carry `project.md`, if you have one, over as the input.

- The change needs a second pull request, or a second repository → `plan`.
- It needs a new module boundary, service, data store, or a dependency that is hard to
  remove → `architect`.
- It needs a new screen, a new flow, or a design system change → `design`.
- A decision belongs to someone outside the conversation → `plan`, as an open item.
- The user asks for the full process.

**If the user asked for `solo`, do not escalate.** Name the condition that broke in one
line, and carry on in `solo`. Only the user's word moves the work to the dedicated
practices.

If you go in circles, the `step-back` rule applies. It comes before escalation.

## Composition

**Check what is installed. Never assume a tool skill is absent.**

- **`github-projects`** or **`jira`** — invoke it before you transition or comment on a
  work item.
- **The `github-source-control` rule** governs the branch and the pull request body.
- **The `development` and `technical-writing` rules** apply to every line, as they do on
  the dedicated path.
- **`quick-edit`** is lighter still: one file, fully specified, no pull request.

Only when no tracker is available, and the work needs a record: keep it in `project.md`,
and say so.
