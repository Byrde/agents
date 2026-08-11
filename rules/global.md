# Working in this project

This repo ships **practice skills** — `plan`, `architect`, `design`, `develop`, `test` —
the team's methods for doing software work. They are broad methodologies, not narrow
tool wrappers. Treat them as the playbook.

**You MUST invoke the matching practice skill before you start.** The trigger is
mechanical. Never decide whether the work "needs" a method.

| Invoke | Before you |
|---|---|
| `plan` | create, split, restructure or re-scope a work item |
| `architect` | change a module boundary, add a dependency, or decide build-vs-buy |
| `design` | build or change a screen, flow or component |
| `develop` | make the first edit of any change that will open a pull request |
| `test` | validate an implementation against its acceptance criteria |

**Invoke once per unit of work, not once per session.** A skill's procedure ends when it
ships. Repeating the last slice from working memory is faster than re-invoking, and that
is the failure, not a shortcut.

**The only exemption** is a single-file edit that opens no pull request. Say when you
take it.

**What skipping costs.** Each practice skill consults the tool skills around it — the
tracker, source control, the design file. Skip the practice skill and none of them are
consulted. Work items go untracked, boards unset, reviews unrequested, and nobody
notices until someone asks.

## Re-grounding

You are probably reading this again because a hook re-injected it. The session has run
long. **Drift is the expected failure now, not an unlikely one.**

Drift does not announce itself. You keep shipping. Tests pass. Nothing errors. And the
method you started with has been replaced by a pattern you invented two slices ago.

**Rules are re-injected. Skills are not.** So a practice skill loaded at the start of a
slice has faded by the time its later steps apply. Those steps are the ones about work
items, reviews and boards.

Check four things every time you read this.

1. **Which practice applies now?** If a unit of work began since you last invoked a
   practice skill, invoke it again. Never carry the previous slice's procedure forward.
2. **What is installed?** Read the available skill list. Never answer from memory, and
   never infer a tool is absent because nobody mentioned it.
3. **What have you skipped?** Name it. A memory, a board update, a review request, a work
   item. An unnamed omission becomes a habit.
4. **Whose process is this?** Point at the rule or skill that told you to work this way.
   If you cannot, you invented it. Return to the documented one.

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

## Tool skills

Installed per project, for the practice skills to consult:

- **github-source-control** — branches, pull requests, code review. A rule, always on.
- **github-projects** — work items, milestones, the board. A skill, so invoke it.
- **figma**, **figma-use** — the design file, and the plugin-API mechanics beneath it.
- **memory** — persistent project memory.
