---
description: Project-wide baseline
trigger: always_on
---

# Working in this project

This repo ships **practice skills** — `plan`, `architect`, `design`, `develop`, `test`,
`debug`, `review`, `quick-edit`, `docs` — the team's methods for doing software work,
and **`solo`**, which runs the same methods at a lighter weight in one pass. Treat them
as the playbook.

## Pick the weight first

Before you start a unit of work, decide how much process it needs. Most work needs less
than the full set of practices. Full ceremony on a small change is waste, not diligence.

**Use `solo`** when every one of these is true:

- The change fits in one pull request, in one repository.
- It adds no module boundary, no service, no data store, and no dependency that is hard
  to remove later.
- The behavior is clear, or one round of questions makes it clear.
- No decision belongs to a person outside this conversation.
- The work is not one slice of an epic that is tracked on a board.

**Use the dedicated practices** (below) when any one of these is false.

**Use `quick-edit`** when the change is one file, fully specified, and opens no pull
request.

**The user's word wins.** "Full process" means the dedicated practices. "Solo" or "keep
it light" means `solo`, with no exception. If the work breaks a condition above, name it
in one line and carry on. Do not ask.

State the decision in one line before you start, for example `solo: one PR, no new
boundary`. If the work breaks a condition while you do it, `solo` tells you how to
escalate.

## The dedicated practices

On the dedicated path, the trigger is mechanical. Never decide whether the work "needs"
a method.

| Run | Before you |
|---|---|
| `plan` | create, split, restructure or re-scope a work item |
| `architect` | change a module boundary, add a dependency, or decide build-vs-buy |
| `design` | build or change a screen, flow or component |
| `develop` | make the first edit of any change that will open a pull request |
| `test` | validate an implementation against its acceptance criteria |
| `debug` | fix anything reported as broken — a failing test, an error, a regression — even when the fix looks obvious |
| `review` | review code, a diff, a branch or a pull request |
| `quick-edit` | make a small, fully specified edit that opens no pull request (a reported bug goes to `debug` first) |
| `docs` | write or substantially rewrite prose for people: a README, a guide, a changelog |

**Run once per unit of work, not once per session.** A practice ends when it ships.
Repeating the last slice from working memory is the failure, not a shortcut.

**What skipping costs.** Each practice consults the tool skills around it — the tracker,
source control, the design file. Skip the practice and none of them are consulted. Work
items go untracked, boards unset, reviews unrequested, and nobody notices.

## How a practice runs

Where your harness installs the practices as **subagents** (Claude Code:
`.claude/agents/`), delegate to the subagent of that name. Otherwise, invoke the skill.

A subagent sees none of this conversation. Its brief is all it knows.

- **Brief it fully.** Give the request, the decisions already made, the work item
  number, the repository, the files, and the constraints.
- **Relay its questions.** A subagent cannot ask the user. When it returns **Needs
  decision**, ask the user, then resume the same subagent with the answer. Never answer
  for the user.
- **Follow its handoff.** When it returns **Handoff**, delegate to the practice it names,
  with the brief it gave.
- **Write its memory.** It returns **Memory candidates**. Write the ones that qualify,
  under the `memory` rule.
- **Check its claims.** Read the evidence it reports before you tell the user the work is
  done.

## Re-grounding

You are probably reading this again because a hook re-injected it. The session has run
long. **Drift is the expected failure now, not an unlikely one.**

Drift does not announce itself. You keep shipping. Tests pass. Nothing errors. And the
method you started with has been replaced by a pattern you invented two slices ago.

**Rules are re-injected. Skills loaded into your own context are not.** A subagent's
method is its system prompt, so it does not fade. A skill you loaded yourself, such as
`solo`, has faded by the time its later steps apply.

Check five things every time you read this.

1. **Which practice applies now, at which weight?** If a unit of work began since you
   last chose, choose again. Never carry the previous slice's procedure forward.
2. **What is installed?** Read the available skill and agent lists. Never answer from
   memory, and never infer a tool is absent because nobody mentioned it.
3. **What have you skipped?** Name it. A memory, a board update, a review request, a work
   item, `project.md`. An unnamed omission becomes a habit.
4. **Whose process is this?** Point at the rule or skill that told you to work this way.
   If you cannot, you invented it. Return to the documented one.
5. **Are you going in circles?** A third fix in the same area, a patch on your own patch,
   a test you changed to make it pass. If yes, apply the `step-back` rule now.

The baselines drift the same way. Architectural standards, the writing standard, the
branch and pull request conventions — each was agreed once, and each erodes as context
fills. A long session is when you re-read them, not an excuse for not having.

## Evidence

Absence of output is not absence of data.

- Never suppress an error stream on a query whose empty result you will act on. Check the
  exit code.
- Corroborate a zero. If a count contradicts what you expect, confirm it against a second
  call before reporting it.
- Never write to a resource you could not read. A blind write duplicates or destroys.
- Where a default value is unavoidable, assert the shape you expected before acting on it.
  A check that cannot fail is not a check.
