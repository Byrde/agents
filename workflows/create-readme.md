# Workflow: Create README

Create or refresh a repository's README overview by deeply analysing the codebase and collaborating with the user.

This is a standalone workflow — it does not compose any jobs. All instructions are self-contained below.

## Tooling

This workflow does not require any external tooling. It operates purely on the local codebase and file system.

## Dependencies

### Required Files

None. This workflow bootstraps a repository from scratch — it is safe to run on an empty or undocumented project.

### Discovered Context

The following context is elicited from the user or inferred from the codebase during the workflow. Do not assume — ask when unsure.

- **Project purpose:** What this repository is for, what problem it solves, who its users are.
- **Key context the code won't reveal:** Business domain nuance, team conventions, or architectural decisions that are not self-evident from reading files.

## Operational Boundaries (non-negotiable)

* **README scope:** You only create or modify the `## Overview` section. You never touch any other section of the README.
* **Accuracy over speed:** You do not write the overview until you have explored the codebase broadly. You do not write to files until the user approves the content.
* **Describe what IS:** The overview reflects the current state of the project — not plans, aspirations, or future work.

## Steps

### Step 1 — Deep Analysis (same context)

**Runs in:** The current conversation context (interactive).

Before writing anything, build a thorough mental model of the repository. Do not rush this. Read broadly, not narrowly.

**Procedure:**

#### 1.1 Structure

Map the top-level directory layout. Identify the major areas of the codebase and what each directory is responsible for. Note anything unusual or non-obvious.

#### 1.2 Tech Stack

Read package manifests, lock files, build configs, and tooling:
- `package.json`, `Cargo.toml`, `pyproject.toml`, `go.mod`, `Gemfile`, `pom.xml`, `build.gradle`, etc.
- CI/CD configs (`.github/workflows/`, `Dockerfile`, `docker-compose.yml`, etc.)
- Framework-specific configs (`next.config.*`, `vite.config.*`, `tsconfig.json`, `tailwind.config.*`, etc.)

Identify: languages, frameworks, runtime, database, infrastructure, key dependencies.

#### 1.3 Architecture

Look for architectural patterns by reading key files:
- Entry points (`main.*`, `index.*`, `app.*`, `server.*`)
- Routing, middleware, API definitions
- Data models, schemas, migrations
- Shared libraries, utilities, internal packages

Identify: monolith vs. microservices, API style (REST, GraphQL, RPC), state management, data flow.

#### 1.4 Domain

Understand what the project **does**, not just how it is built:
- Read any existing README, CONTRIBUTING, or docs
- Scan test names for domain language
- Look at model/entity names
- Check for seed data, fixtures, or example configs

#### 1.5 History

Quickly scan recent git activity for context:
- `git log --oneline -20` for recent trajectory
- `git log --oneline --all --graph -10` for branching patterns

#### 1.6 Existing README

If a README already exists, read it in full. Identify:
- What sections exist
- Whether an `## Overview` section is present
- What content in the overview is still accurate vs. stale

#### 1.7 Present findings

Present your analysis to the user as a structured summary. Let them correct misunderstandings, fill gaps, or redirect focus.

**Completion gate:** The user confirms the analysis is accurate or provides corrections that have been incorporated.

### Step 2 — README Overview (same context)

**Runs in:** The current conversation context (interactive).

#### What the overview is

A **40,000-foot view** of the project. Someone reading it should understand:

- What the project is and what problem it solves
- The tech stack and primary languages
- How the codebase is organized (directory map with one-line descriptions)
- Key architectural decisions and patterns
- How the major pieces connect

#### What the overview is NOT

- Not a tutorial or getting-started guide
- Not a changelog
- Not an exhaustive API reference
- Not aspirational (describe what IS, not what could be)

#### Writing rules

- Be concrete and specific. Name the actual frameworks, libraries, and patterns.
- Use the project's own terminology — mirror the naming in the code.
- Keep it scannable: short paragraphs, tables, and lists over prose walls.
- A directory map (tree or table) is mandatory.
- If the project is small, the overview can be short. Do not pad.

#### Procedure

1. **Draft** the `## Overview` section following the writing rules above.
2. **Present the draft** to the user for feedback.
3. **Iterate** based on their input. This may take multiple rounds.
4. **Write to the README** only after the user approves the content.

#### Updating an existing README

If the README already has an `## Overview` section:
- **Update** facts that have changed (stack, structure, architecture).
- **Prune** content that is no longer accurate.
- **Add** anything new that is missing.
- **Do not touch** any section outside of `## Overview`. Leave the rest of the README exactly as-is.

If the README exists but has no `## Overview` section, insert one after the title (before any other section).

If no README exists, create one with a title and the overview section only. The user can add other sections later.

**Completion gate:** The `## Overview` section is written to the README and the user is satisfied.
