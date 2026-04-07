# .agents

A structured multi-agent framework for software development. It defines specialist roles, composable workflows, shared practices, and tool integrations that orchestrate the full lifecycle — from UX design through architecture, planning, implementation, and QA.

## Setup

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