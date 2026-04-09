# Workflow: Work

Take a spec'd work item through implementation and QA validation.

## Jobs

This workflow composes the following jobs, in order:

1. **Software Developer** — `.agents/jobs/develop.md`
2. **UI Designer** *(conditional)* — `.agents/jobs/design-ui.md`
3. **QA Specialist** — `.agents/jobs/test.md`

## Tooling

**This workflow operates entirely in GitHub.** All branch creation, issue state transitions, pull requests, and QA reporting must be performed through the GitHub API using the configuration and conventions defined in `.agents/tools/github.md`.

Concretely:
- **Branches** follow the naming conventions in `.agents/tools/github.md` (`feature/`, `bugfix/`, `patch/`).
- **Issue lifecycle** (In Progress → Ready to Test → Done) is managed on the GitHub Project board.
- **Pull requests** follow the format and content requirements in `.agents/tools/github.md`.
- **All communication** (implementation notes, QA results, defect reports) is posted as comments on the relevant GitHub issue.

## Dependencies

### Required Files

These files **must** exist and be fully populated before this workflow can execute. If any are missing or incomplete, **fail immediately** and tell the user what needs to be created.

| File | Purpose |
| --- | --- |
| `.agents/tools/github.md` | GitHub account, repository, project board configuration, and conventions. |

### Optional Files

| File | Required | Purpose |
| --- | --- | --- |
| `.agents/tools/figma.md` | **Only when UI design step is triggered.** | Figma team, project, design system file, and conventions. |

### Work Item (mandatory, no exceptions)

A **fully spec'd GitHub issue** must be identified before execution begins. The issue must have acceptance criteria, and should have any architectural comments from a prior planning workflow.

If no issue is provided and no matching item exists on the project board, **stop** and suggest the user plan some work first. There are no patch exceptions in this workflow — all work flows through a tracked issue.

## Steps

### Step 1 — Developer Review (same context)

**Job:** Software Developer (`.agents/jobs/develop.md`)
**Runs in:** The current conversation context (interactive).

**Procedure:**

1. **Validate dependencies:** Confirm `.agents/tools/github.md` exists and is populated. Fail if not.
2. **Identify the work item:** Confirm the GitHub issue with the user. Read the issue body **and all comments** — acceptance criteria, architectural decisions, design decisions, and any prior discussion.
3. **Verify current state:** Check that the issue is not already implemented (merged PRs, closed-as-done, codebase matches criteria). If partially implemented, map what remains.
4. **Extract and verify requirements:** List implicit assumptions or ambiguities. Resolve with the user before proceeding. If gaps require a spec update, halt and route back to planning.
5. **Assess design readiness:** Determine whether this work item requires UI design (e.g. new screens, components, or visual changes). Check the issue comments for an existing **`## UI Design`** comment — this indicates that visual design has already been completed. If the task requires UI work **and** no `## UI Design` comment exists, flag that Step 2 (UI Design) will run before implementation.
6. **Flag to proceed:** Present the developer's understanding of the work — what will be built, what the tests will cover, whether UI design is needed (and whether it already exists), and any decisions made. **Wait for explicit user confirmation** before proceeding.

**Completion gate:** The user has confirmed the developer's understanding and given the go-ahead.

### Step 2 — UI Design (CONDITIONAL, MUST RUN AS SUBAGENT)

**Job:** UI Designer (`.agents/jobs/design-ui.md`)
**Workflow:** Design UI (`.agents/workflows/design-ui.md`)
**Runs in:** A sub-agent (isolated context, launched after Step 1 completes).

**This step runs ONLY IF** all of the following are true:
- The work item involves UI changes (new screens, components, or visual modifications).
- No `## UI Design` comment exists on the GitHub issue (i.e. visual design has not been completed in a prior session).
- `.agents/tools/figma.md` exists and is populated.

If any condition is not met, skip to Step 3.

**Input to sub-agent:**
- The GitHub issue number and repository.
- The acceptance criteria and any architectural/UX decision comments from the issue.
- The contents of `.agents/tools/figma.md`.
- Instruction to execute the Design UI workflow (`.agents/workflows/design-ui.md`) scoped to this issue.

**Procedure:**

1. Execute the Design UI workflow (`.agents/workflows/design-ui.md`) in its entirety, scoped to the GitHub issue.
2. On completion, post a **`## UI Design`** comment on the GitHub issue containing:
   - **Decisions:** A summary of the visual design decisions — direction chosen, key trade-offs, and rationale.
   - **Figma link:** A direct link to the Ready for Development page in the Figma feature file.
   - **Implementation notes:** Token references, component variant usage, interaction details, and anything a developer needs to know.
   - **Open items:** Any unresolved questions or deferred decisions.

**Completion gate:** The `## UI Design` comment is posted on the issue with design decisions and Figma link. The sub-agent has completed the Design UI workflow.

### Step 3 — Implementation (MUST RUN AS SUBAGENT)

**Job:** Software Developer (`.agents/jobs/develop.md`)
**Runs in:** A sub-agent (isolated context, launched after Step 1 — or Step 2 if it ran — completes).

**Input to sub-agent:**
- The verified requirements and decisions from Step 1.
- Any design decisions from the `## UI Design` comment (from Step 2 or a prior session).
- The GitHub issue number and repository from `.agents/tools/github.md`.
- The conventions from `.agents/tools/github.md`.

**Procedure:**

1. **Create branch** following `.agents/tools/github.md` conventions.
2. **Move issue** to **In Progress** on the project board.
3. **TDD loop:** Write contract tests encoding the acceptance criteria, implement to green, refactor within scope. If a `## UI Design` comment exists, use the referenced Figma designs and implementation notes to guide the visual implementation.
4. **If blocked:** Stop implementation. Comment on the GitHub issue describing the gap and escalate back to the user.
5. **Open PR** following the format in `.agents/tools/github.md`.
6. **Update issue:** Move to **Ready to Test**. Comment on the issue with what was done, the PR link, and anything the tester should know.

**Completion gate:** PR is open, issue is in Ready to Test, and the implementation comment is posted.

### Step 4 — QA Validation (MUST RUN AS SUBAGENT)

**Job:** QA Specialist (`.agents/jobs/test.md`)
**Runs in:** A sub-agent (isolated context, launched after Step 3 completes).

**Input to sub-agent:**
- The GitHub issue number, PR number, and repository from `.agents/tools/github.md`.
- The acceptance criteria from the issue.
- The implementation summary comment from Step 3.
- Branch/commit to test against.

**Procedure:**

1. **Execute the review protocol** as defined in the QA Specialist job (`.agents/jobs/test.md`): baseline validation, standards validation, and entropy testing.
2. **If defects found:** Reject the work. Comment on the GitHub issue with the defect report (defect description, reproduction steps, expected vs actual, environmental context). Move the issue back to **In Progress**. Escalate to the user.
3. **If passed:** Comment on the issue confirming QA approval. Move the issue to **Done**.

**Completion gate:** The issue is either rejected with documented defects and returned for fixes, or approved and marked done. The user is notified of the outcome.
