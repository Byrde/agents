---
description: Create or update the specification of a feature and store it in spec.md.
---

## User Input

```text
$ARGUMENTS
```

## Outline

1. **Choose the feature directory.** Do not ask the user for it.
   - A work item is in play: `specs/<work item number or key>-<short-name>`, for
     example `specs/42-export-csv`.
   - No work item: `specs/<short-name>`.
   - The directory exists: this is an update. Edit its `spec.md`.

2. Create the directory and write `.specify/feature.json`:
   ```json
   { "feature_directory": "<feature_directory>" }
   ```

3. **Read first.** Read the work item and all its comments when there is one. Read the
   code that the feature touches.

4. **Ask once.** Collect the questions whose answers change the scope or the behavior.
   Ask them in one round. Do not ask what the code or the request answers.

5. Write `<feature_directory>/spec.md` with these sections:
   - **Intent** — what the user wants and why, in two or three sentences.
   - **User stories** — one for each slice that can ship alone, in priority order
     (P1, P2, P3). Each story has acceptance scenarios, one per line, in
     `Given / When / Then` form. A test must be able to check each one.
   - **Out of scope** — what this feature does not do.
   - **Assumptions** — each default you chose where the request was silent.
   - **Open questions** — each one with the person who decides it. Never guess a
     decision that belongs to someone outside the conversation.

   The `technical-writing` rule sets the level. Write no implementation detail. That
   belongs in `plan.md`.
