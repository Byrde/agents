# The working loop — one pass per unit of work

Every unit of work follows this loop. A unit is one slice you would open one pull
request for.

Read this again when the scope changes. A loop set at the start of a session does not
survive a change of scope on its own.

## 1. Before you start

1. Invoke the practice skill for the work. Use `plan`, `architect`, `design`,
   `develop` or `test`.
2. Search the project's memory for earlier decisions on the area you will touch.
3. Read the rules in this directory again if the scope changed.

Invoke the skill once per unit, not once per session. A skill's procedure ends when it
ships. It does not carry into the next slice. Repeating the last slice from memory is
cheaper than re-reading the skill, and that is the trap.

## 2. While you work

1. State each assumption. Never carry an unstated one.
2. Stop and ask when two readings lead to different work.
3. Report a defect you find. Never repair it silently outside the scope.

## 3. Before you reply

Complete every step below. Report each one, including a step you skipped.

1. Save a memory for any decision that outlives the session.
2. Add that memory to the index in the same step.
3. Open the pull request. Never leave a pushed branch without one.
4. Request review per `CODEOWNERS`. If none exists, ask who reviews.
5. Update the work item and the board status.
6. State what you skipped, and why.

Name each step in the summary. A summary that cannot say "memory: none written" hides
the gap.

## Guards

- **Absence of data is not data.** Never suppress an error stream on a query whose
  empty result you will act on. Check the exit code instead.
- **Corroborate a zero.** If a count is zero, confirm it against a second signal.
- **A check that cannot fail is not a check.** Break it once. Confirm it fails.
- **Fix the class, not the instance.** After you fix one silent default, search for the
  same pattern elsewhere.
- **Migrate every identifier.** Before you delete a document, list its names, paths and
  numbers. Give each one a new home.

## Why this rule exists

An agent read every rule in this directory at the start of a session. It then shipped
eight pull requests without writing a memory, opening a board item, or requesting a
review.

The rules had loaded. Nothing re-asserted them. Static context loses to the most recent
tool result, so a rule needs a trigger. This file is that trigger, and step 3 is the
gate.
