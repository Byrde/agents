# Skill Capabilities

This is the shared vocabulary that makes implicit composition between skills work. Practice skills are written in plain English using the **verb + noun operations** below. Tool skills declare which operations they own. Claude routes the work by matching the prose against the declarations — there are no placeholders, no "use the X tool" phrasings, and no orchestrator skills.

## How it works

- **Practice skills** describe procedures in operations from the taxonomy below. They never name a specific tool or product.
- **Tool skills** list the operations they own in their `description` frontmatter. The description is what Claude routes on.
- **One operation, one owner per project.** If two installed tool skills would claim the same verb + noun pair, one of them is mis-scoped — split it or rename.
- **Verb + noun, not noun alone.** "Comment" is ambiguous; "comment on work item" and "leave review comment" route to different owners.

## Operation taxonomy

Grouped by domain. Each tool skill claims a subset.

### Source control

- create branch
- open pull request
- request review
- leave review comment
- merge pull request

### Project management

- create work item
- transition work item
- comment on work item
- set work item field (priority, size, status, type, etc.)
- link work item (to milestone, parent, dependency)
- place work item on board
- create milestone

### Design

- read design tokens
- read design component
- add design token
- add design component
- publish design library
- create design page
- open design file
- comment on design
- mark frame ready for development
- archive frame

### Documentation

- create document
- update document
- link document

## Authoring a tool skill

1. Pick the operations your tool legitimately owns in this project. Reuse existing verb + noun pairs.
2. If you need a new operation, add it to the taxonomy above first — extending the vocabulary is a deliberate act.
3. Put the operations into your skill's `description` so Claude can route on them.
4. If your provider covers multiple domains (e.g., GitHub covers source-control **and** project-management), **split into separate skills** — one per domain (`github-source-control`, `github-projects`). Each is independently opt-in at setup.

## Authoring a practice skill

1. Write the procedure in plain English using verb + noun operations from this list.
2. Never name a specific tool. Never write "use the project-management tool." Just write "create the work item."
3. For operations whose owner may not be installed, include an explicit fallback ("if no work-item tracker is configured, gather requirements conversationally and deliver in chat").

## Adding a new domain

If you genuinely need a new domain (e.g., observability, deployment), add it as a new section here with its operations **before** writing the practice or tool skills that use it. The taxonomy is the contract.
