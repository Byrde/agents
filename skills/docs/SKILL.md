---
name: docs
description: "**MUST be invoked** before you write or substantially rewrite prose for people: a README, a guide, reference docs, a runbook, a changelog, release notes. NEVER describe behavior you have not checked in the code. Skipping it means docs that read well and are wrong: stale commands, invented options, examples that do not run. Write documentation for a named reader and purpose, verify every claim against the source, and follow the technical-writing standard."
category: practice
---

# Docs

Write documentation a named reader can act on, and that is true.

## Mindset

- **One reader, one job.** Name who reads this and what they must be able to do after. Cut what does not serve that.
- **The code is the source of truth.** Every command, option, default and output in the doc must match the code as it is now. Check it, do not recall it.
- **Examples must run.** An example that fails teaches the reader to distrust the whole page.
- **Structure follows the task.** Put what the reader does first in the order they do it. Put reference material where they can look it up.
- **The standard is not optional.** The always-on `technical-writing` rule sets the language: ASD-STE100, at the level the document calls for.

## Inputs

- **The subject** — the feature, tool, process or change to document.
- **The reader and purpose** — who reads it, and what they must do afterwards.
- **Where it lives** — the file or document, and the conventions already in place there.

## Procedure

1. **Frame.** State the reader, the purpose, and the scope. Read the existing documentation around it, so the new text fits instead of repeating or contradicting it.
2. **Gather the facts from the source.** Read the code, the configuration and the help output. Run the commands. Note every name, flag, default, path and output exactly as it is.
3. **Outline.** Order the sections by what the reader does. Put the most common task first. Keep reference tables apart from procedures.
4. **Write.** Follow the `technical-writing` rule. Procedures are strict. Use real values in examples, not placeholders that cannot run.
5. **Verify.** Run every command and example in the doc. Check every link and path. Re-read each claim against the source.
6. **Deliver.** **Create the document** or **update the document**. When the documentation lives in a tool, **link the document** to the work item it belongs to. Report what you checked.

## When to halt

- The behavior is undecided or the code disagrees with the request. Ask which is right before you write it down.
- You cannot run or read what you are documenting. Say so, and mark what you could not verify.
- The doc needs a decision that belongs to someone else, such as a policy or a support promise. Ask for it.

## Composition

**Check what is installed. Never assume a tool skill is absent.** A tool skill is inert
until you invoke it. A rule is already in context. See `global.md` → Tool skills for
which is which.

- **The `technical-writing` rule** governs every sentence.
- **A documentation tool skill**, when one is installed, owns **create document**,
  **update document** and **link document**. Without one, write the file in the
  repository.
- **`develop`** owns documentation that ships inside a code change. Follow this skill
  for the writing and that one for the pull request.
