---
description: Project-wide baseline
trigger: always_on
---

# How we work

You know how to plan, build, debug and document software. This rule states only what
this project does differently, and the habits that fail when nobody states them.

## How much process

Pick the level from the request. Say which level you picked, in one line, before you
start. The user's word on the level wins. "Just build it" means the first level.

| The request | What you do |
|---|---|
| A fix, or a change that is small and clear | Build it under the rules below. Write no spec. |
| A feature, or a request that leaves open what to make | Write a spec, get it approved, then build from it. |
| A new or changed screen, flow or component | Run `design` before you build. |

### A spec

When the project has a `.specify/` directory, Spec Kit holds the phases as `speckit-*`
skills. You run them. Never ask the user to run one.

1. Run `speckit-specify`. It asks its questions in one round and writes `spec.md`.
2. Show the spec to the user, and wait for approval.
3. When a tracker tool skill is installed, invoke it to publish the spec as a work item.
4. Run `speckit-plan`, `speckit-tasks`, `speckit-implement` and `speckit-converge` in
   sequence. Stop only for a structural decision in the plan. If `speckit-converge`
   adds tasks, run `speckit-implement` again.
5. Run `review` on the result.

For a spec with more than three user stories, or with open questions, also run
`speckit-clarify` before the plan and `speckit-analyze` before the implementation.

Commit the feature directory with the change. The spec is the record of what the user
asked for and why.

Without `.specify/`, write the intent and the acceptance criteria, in
`Given / When / Then` form, on the work item or in the conversation. Get them approved.
Then build.

## Skills

`design` is a conversation with the user. Run it in this conversation.

`review` runs as a subagent where the harness has subagents. It sees none of this
conversation. Give it the change, the intent and the scope. When it returns **Needs
decision**, ask the user, then resume it with the answer. Write the **Memory candidates**
it returns, under the `memory` rule. Read its evidence before you report its verdict.
Run it when the user asks for a review, and at the end of a spec.

**Tool skills.** A tool skill owns each external system: the tracker, the design file,
analytics. Read the skill list. Never assume a tool skill is absent. Invoke it before you
touch its system, because it carries conventions you will otherwise get wrong.

## Before you build

- **Read first.** Read the code around the change. Read a referenced work item and all
  its comments.
- **Ask once.** Collect the questions that block you, and ask them in one round. Do not
  ask what the code or the request answers. State the assumptions you make.
- **Structural decisions belong to the user.** Before you add a module boundary, a
  service, a data store, or a dependency that is hard to remove, stop. Give the options,
  the trade-offs and your recommendation. Record the decision and the rejected option
  in `plan.md`, on the work item, or in the pull request body.
- **Distrust small dependencies.** For a small need, write a minimal version in the
  project before you add a library that has one maintainer.

## While you build

- **Test first.** Write the test that encodes the acceptance criteria. Then implement
  until it passes.
- **Reproduce before you fix.** When something is reported as broken, make it fail on
  demand before you edit. Fix the cause, not the place where the symptom shows. Leave a
  test that fails without the fix.
- **Stay in scope.** Change what the request asks for. Add no cleanup and no feature
  beside it. If the work grows past the request, say so before you continue.
- **Keep the tracker current.** When a work item is in play, transition it when you
  start and when the pull request opens. Comment with the pull request link and what a
  reviewer must know.
- **Reuse UI components.** When the project keeps a `figma-code-map.json`, read it
  before you build UI. Extend the mapped component before you add a second one. Update
  the entry on an add or a rename, then run `.agents/tools/figma-code-map-lint.sh`.
- **Check prose against the source.** Before you document a command, an option, a
  default or a path, read it in the code. Run each example.

## Before you say it is done

- Run the tests, the linter and the build that cover the change. Read the results.
- Check each acceptance criterion one by one.
- Attack the change with two or three inputs it is likely to get wrong: empty, invalid,
  the error path.
- Report what changed, what you ran and its result, and what you did not check.

## Long sessions

A hook shows you this rule again during a long session. Drift is the expected failure
then, and it does not announce itself. Check three things each time.

1. **What did you skip?** Name it: a test, a tracker update, a memory, a review request.
   An unnamed omission becomes a habit.
2. **Whose process is this?** Point at the rule or skill that told you to work this way.
   If you cannot, you invented it.
3. **Are you going in circles?** A third fix in one area, a patch on your own patch, a
   test you changed to make it pass. If yes, apply the `step-back` rule now.

The other rules drift the same way. Read one again when your next step touches it.

## Evidence

Absence of output is not absence of data.

- Never suppress an error stream on a query whose empty result you will act on. Check the
  exit code.
- Corroborate a zero. If a count contradicts what you expect, confirm it against a second
  call before reporting it.
- Never write to a resource you could not read. A blind write duplicates or destroys.
- Where a default value is unavoidable, assert the shape you expected before acting on it.
  A check that cannot fail is not a check.
