# Working in this project

This repo ships **practice skills** — `plan`, `architect`, `design`, `develop`,
`test` — the team's methods for doing software work.

**You MUST invoke the matching practice skill before you start.** The trigger is
mechanical. Do not decide whether the work "needs" a method.

| Invoke | Before you |
|---|---|
| `plan` | create, split, restructure or re-scope a work item |
| `architect` | change a module boundary, add a dependency, or decide build-vs-buy |
| `design` | build or change a screen, flow or component |
| `develop` | make the first edit of any change that will open a pull request |
| `test` | validate an implementation against its acceptance criteria |

**Invoke once per unit of work, not once per session.** A skill's procedure ends when
it ships. It does not carry into the next slice. Repeating the previous slice from
working memory is faster than re-invoking, and that is the failure, not a shortcut.

**The only exemption** is a single-file edit that opens no pull request. Say when you
take it.

**What skipping costs.** Each practice skill consults the tool skills that own the
surfaces around it — the tracker, source control, the design file. Skip the practice
skill and none of those are consulted. Work items go untracked, boards go unset,
reviews go unrequested, and nobody notices until someone asks.

Unlike a typical skill (a narrow *how* for one tool), these are broad
methodologies describing *how we work*. That's a deliberate stretch of the
convention, and it's fine — treat them as the project's playbook.

Depending on the project, **tool skills** may also be installed for the practice
skills to lean on:

- **github-source-control** — branches, pull requests, code review
- **github-projects** — work items, milestones, the project board
- **figma** — the project's Figma file: reusable components, tokens, design work
- **figma-use** — the Figma plugin-API mechanics the `figma` skill builds on
- **memory** — persistent project memory (recall before work, save decisions)

## Evidence

Absence of output is not absence of data.

- Never suppress an error stream on a query whose empty result you will act on. Check
  the exit code instead.
- Corroborate a zero. If a count contradicts what you expect, confirm it against a
  second call before you report it.
- Never write to a resource you could not read. A blind write duplicates or destroys.
- Where a default value is unavoidable, assert the shape you expected before acting on
  it. A check that cannot fail is not a check.
