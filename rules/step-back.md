---
description: Stop patching and re-evaluate the design as a whole when the work goes in circles
trigger: always_on
---

# Step back — stop patching, re-evaluate the design

Each patch looks reasonable alone. A run of them is a sign that the design is wrong,
and the next patch will not fix it. Activity is not progress.

## Signals

Step back when you see **any one** of these:

- **The third attempt.** You are about to try a third fix for the same failure or the
  same area.
- **A patch on a patch.** The change fixes, or works around, a change you made in this
  session.
- **The fix moves the bug.** A fix makes a different test, path or case fail.
- **Special cases pile up.** You add a flag, a branch, a retry or an `if` for one input,
  so that the general code can stay as it is.
- **You bend the check.** You are about to loosen a test, an assertion, a type or a lint
  rule so that the work passes.
- **You cannot explain it.** The last fix worked, or failed, and you cannot say why.
- **You undo yourself.** You revert, or rewrite, your own work from earlier in the
  session.
- **The user is frustrated.** "Still broken", "again", "this is the same problem", "you
  already tried that".

Do not wait for two signals. One is enough.

## Procedure

1. **Stop editing.** Make no further change to the code until step 5.
2. **Write the record.** State the goal in one sentence. List each attempt, what it
   changed, and what it showed. Write it in the conversation, or in `project.md` if one
   is in use.
3. **Name the assumptions.** List what each attempt took as given: about the data, the
   contract, the library, the environment, the requirement. Mark each one as verified or
   assumed. An assumed one is the first suspect.
4. **Look at the whole design.** Ask whether the approach is the wrong shape for the
   problem, not only whether this line is wrong. Read the code around the area as a
   whole. Check the requirement again: the problem may be one that nobody asked to
   solve.
5. **Propose options.** Give two or three directions, with a recommendation:
   - Continue the current approach, if you can name the one thing the patches missed.
   - Redesign the part that keeps breaking.
   - Revert to the last state that worked, and start again with what you now know.
6. **Ask the user before you continue.** This is a decision about direction. It belongs
   to the user. Keep the summary short: the goal, what failed, the cause you suspect, the
   options.

## After the decision

- Remove the patches that the new direction makes unnecessary. Leave no workaround for a
  problem that no longer exists.
- If you learned why the first approach failed, and the code will not show it, write a
  memory.
- If you run as a subagent, return the record and the options under **Needs decision**.
