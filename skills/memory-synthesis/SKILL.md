---
name: memory-synthesis
description: "Audit and consolidate the whole memory bank: verify each memory against the code and the history, fix or delete what no longer holds, merge fragments and duplicates into single memories that hold up, repair the links, and rebuild the index. Use it when the user asks to clean up, consolidate, audit or synthesize memory, or when recall turns up contradictions or stale claims. Shows the full change set and gets approval before it deletes or merges anything."
category: maintenance
---

# Memory synthesis

Make the memory bank smaller, truer and easier to recall. Every memory that remains
must be correct today, and must earn its place.

## Mindset

- **Verify, do not trust.** A memory states what was true when someone wrote it. Check
  each claim against the code, the configuration and the git history as they are now.
- **Fewer, stronger memories.** Three fragments about one topic recall worse than one
  complete memory. Merge them.
- **Consolidate, do not bundle.** One fact per memory still applies. Merge memories that
  state the same fact, or parts of it. Never merge unrelated facts into one file because
  they share a topic.
- **The memory rule is the standard.** What qualifies, and what does not, is set by the
  `memory` rule. A memory that fails it goes, even if it is true.
- **Deletion is the user's call.** Propose. Apply only what the user approves.

## Inputs

- **The memory directory.** Find it in this order:
  1. `autoMemoryDirectory` in `.claude/settings.local.json` or `.claude/settings.json`.
  2. `memory/` at the project root.
  3. The harness's own project memory directory, such as
     `~/.claude/projects/<project>/memory/`.
- **The index**, `MEMORY.md`, in that directory.
- **A focus**, if the user gives one: a topic, a type, or a date range.

If you find more than one memory directory, list them and ask which to audit.

## Procedure

1. **Inventory.** Read `MEMORY.md` and every memory file. For each file, note the name,
   the type, the claim, the links, and when git last changed it. Note the files that the
   index does not list, and the index lines that point to no file.
2. **Verify each claim.**
   - It names a file, function, flag, command or setting: search for it. Is it still
     there, and does it still do what the memory says?
   - It records a decision: does the code still follow it? Did a later commit reverse
     it?
   - It states project status, a deadline or a plan: compare it with the git log and
     today's date.
   - It points to an external resource: keep it, unless you have evidence that the
     resource is gone.

   Mark each claim **holds**, **stale** (partly true), **wrong**, or **unverifiable**.
   Give the evidence for each mark.
3. **Decide each memory.**
   - **Keep** — it holds and it qualifies.
   - **Update** — it is stale. Correct the claim, and keep the reason.
   - **Merge** — it states the same fact as another memory, or part of it. Name the
     surviving file.
   - **Delete** — it is wrong, superseded, only mattered to one conversation, or
     restates the code, the git history or a rule.
   - **Ask** — it is unverifiable, or the evidence conflicts. Never delete on a guess.
4. **Present the change set.** Show one table: memory, mark, decision, reason. Put the
   deletes and the merges first. Get the user's approval. Apply only what they approve.
5. **Apply.**
   - Write each merged memory as one complete memory. Keep the frontmatter format of the
     directory. Keep every **Why:** and **How to apply:** line that still holds. Choose
     the clearest name.
   - Delete the files that were merged or removed.
   - Rewrite every `[[link]]` that pointed to a merged or deleted memory.
   - Convert each relative date to an absolute one.
   - Rebuild `MEMORY.md`: one line per memory, grouped by type, every file listed, no
     line without a file.
6. **Report.** Give the counts kept, updated, merged and deleted. List what you deleted
   and why. List the memories that are still unverifiable.

## When to halt

- You cannot find a memory directory. Report where you looked.
- A claim concerns a system you cannot reach, such as a dashboard or a third-party
  service. Mark it unverifiable and ask. Do not delete it.
- The user approves nothing. Change nothing, and report the audit only.

## Composition

- **The `memory` rule** sets what qualifies and how a memory is written.
- **Source control.** If the memory directory is tracked in git, the change goes in one
  commit, or in one pull request if the team reviews memory changes.
