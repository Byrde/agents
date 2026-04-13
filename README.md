# .agents

A structured multi-agent framework for software development. It defines specialist roles, composable workflows, shared practices, and tool integrations that orchestrate the full lifecycle — from UX design through architecture, planning, implementation, and QA.

## Usage

Use this repository as a submodule so another project keeps `.agents` at a pinned revision and can update it deliberately.

From the **root** of the host repository:

```bash
git submodule add https://github.com/Byrde/agents.git .agents
git commit -m "Add .agents submodule"
```

**Cloning a host repo that already includes this submodule:** use `git clone --recurse-submodules <host-repo-url>`, or after a plain clone run `git submodule update --init --recursive`.

**Updating the submodule** `git submodule update --remote .agents` follows the submodule’s configured remote branch.

## Init

One-command bootstrap that sets up mempalace, installs rules and skills, and launches the `/create-readme` workflow:

```bash
cd /your/project
.agents/scripts/init.sh
```

The script runs four steps in sequence:

1. **Mempalace setup** — runs `setup-memory.sh` interactively
2. **Rules** — copies `.agents/rules/` into `.cursor/rules/` and `.claude/rules/`
3. **Skills** — copies `.agents/.skills/` into `.cursor/skills/` and `.claude/skills/`
4. **Claude CLI** — launches `claude` with the `/create-readme` workflow to bootstrap the README overview

**Requires:** `claude` (Claude Code CLI), plus all `setup-memory.sh` requirements (`python3`, `jq`)

## Setup Tools

### GitHub

Configures the GitHub MCP server, renders `.agents/tools/github.md` from template, and merges MCP config into your editor.

**Requires:** `gh` (GitHub CLI, authenticated), `jq`, `python3`

```bash
cd /your/project
.agents/scripts/setup-github.sh
```

The script will interactively walk you through selecting your GitHub account, organization/owner, repository, and project board. It writes:

- `.agents/tools/github.md` — rendered tool configuration
- `.cursor/mcp.json` — Cursor project MCP
- `.mcp.json` — Claude Code project MCP

### Figma

Configures the Figma MCP server, renders `.agents/tools/figma.md` from template, and merges MCP config into your editor.

**Requires:** `curl`, `jq`, `python3`, a [Figma Personal Access Token](https://www.figma.com/developers/api#access-tokens) with `file_content:read` and `projects:read` scopes

```bash
cd /your/project
.agents/scripts/setup-figma.sh
```

The script will ask for your PAT, then interactively walk you through selecting your Figma team (via URL), project, and Design System file. It writes:

- `.agents/tools/figma.md` — rendered tool configuration
- `.cursor/mcp.json` — Cursor project MCP
- `.mcp.json` — Claude Code project MCP

The Figma MCP server uses OAuth — authentication happens interactively through your editor (Cursor or Claude Code) on first use.

### Mempalace

Installs and configures the [mempalace](https://github.com/milla-jovovich/mempalace) memory system for persistent AI context across conversations. Sets up MCP servers, auto-save hooks, and ignore patterns for both editors.

**Requires:** `python3`, `jq`

```bash
cd /your/project
.agents/scripts/setup-memory.sh
```

The script installs mempalace (via pip, uv, or ensurepip), initialises a project-local palace, and writes:

- `.mempalace/` — project-local palace data
- `.mempalace/hooks/` — save and precompact hook scripts
- `.mempalaceignore` — ignore patterns for mining (node_modules, etc.)
- `.cursor/mcp.json` — Cursor project MCP
- `.cursor/hooks.json` — Cursor auto-save hooks (stop + preCompact)
- `.mcp.json` — Claude Code project MCP (fallback if CLI unavailable)
- `.claude/settings.local.json` — Claude Code auto-save hooks

To mine project files after setup: `.agents/scripts/setup-memory.sh mine`

### Doctor

Diagnoses the health of all MCP servers configured by the setup scripts for both Cursor and Claude Code.

```bash
cd /your/project
.agents/scripts/doctor.sh
```

Checks configuration, authentication, and server reachability for GitHub, Figma, and Mempalace.

## Jobs

Each job defines a specialist role with a clear scope boundary, dependencies, and operating rules.

| Job | Role | Scope |
| --- | --- | --- |
| `architect.md` | Marcus — Systems Architect | Macro-level system design, build-vs-buy decisions, Mermaid diagrams |
| `design-ux.md` | Julian — UX Designer | User flows, wireframes, annotations, unhappy paths |
| `design-ui.md` | Leo — UI Designer | One component at a time — tokens, variants, states, visual design |
| `plan.md` | Elias — Technical Planner | Decomposing requests into spec'd, tracked work items |
| `develop.md` | Victor — Software Developer | TDD implementation from clear requirements — halts on ambiguity |
| `test.md` | Silas — QA Specialist | Adversarial testing — acceptance criteria, standards, entropy |

## Workflows

Workflows compose jobs into gated pipelines. Each step has explicit dependencies, a completion gate, and a defined handoff.

| Workflow | Jobs | Purpose |
| --- | --- | --- |
| `architect.md` | Architect | Design or refine system architecture (ad-hoc or issue-scoped) |
| `design-ux.md` | UX Designer | Map flows and wireframe a feature in Figma |
| `design-ui.md` | UI Designer | Visually design a component using the design system in Figma |
| `plan.md` | Planner → Architect | Decompose a request into GitHub issues, then enrich with architecture |
| `develop.md` | Developer | Implement a feature or fix (ad-hoc or issue-scoped) |
| `test.md` | QA Specialist | Validate an implementation against its requirements |
| `work.md` | Developer → QA | Full pipeline — take a spec'd issue from implementation through QA |
| `create-readme.md` | — | Create or refresh the README overview |