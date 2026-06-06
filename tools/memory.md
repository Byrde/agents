# Memory — when to reach for it

This project has a **persistent memory palace** (mempalace, via the `memory`
skill + MCP server). Treat it as a first-class source of truth, not a last
resort. Storage isn't memory — *consulting* it is.

## Recall — aggressively, before you act

- **Before any non-trivial task**, search memory for prior decisions,
  conventions, and context on the area you're about to touch. Past-you (or a
  teammate) may have already solved or decided this.
- **Before asserting anything about a past decision, a person, a project, or a
  "why is it like this?"** — search first. Don't reconstruct from the code
  alone when the rationale may be saved. Wrong is worse than slow.
- Recall is cheap; bias toward checking. If nothing relevant comes back,
  proceed and save what you learn.
- Search **semantically** (describe what you're after), not just by keyword.

## Save — when it won't be obvious later

- After a meaningful decision: what was chosen, what was rejected, and why.
- After a non-obvious constraint, gotcha, convention, or domain fact.
- When the user says "remember this" or gives durable guidance on how to work.
- Honor auto-save and pre-compaction checkpoints when prompted — **actually
  save**, don't skip them.
- Use verbatim quotes when exact wording matters; convert relative dates to
  absolute ones before saving.

## Don't

- Don't hoard what the code, git history, or README already make plain — memory
  is for what a newcomer couldn't reconstruct from the repo alone.
- Don't trust a recalled entry blindly: it reflects what was true when written.
  Verify a named file, flag, or function still exists before acting on it.

The `memory` skill covers the *how* (tools, rooms, mining); this rule is about
*when* — and the answer is "more often than feels necessary."
