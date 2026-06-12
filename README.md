# .agents

A library of self-contained, opinionated Claude Code skills for software development. Drop it into any repository as a submodule. Two kinds of skills compose freely via shared verb+noun vocabulary: **practice skills** (the *what* — develop, plan, architect, design, test, create-readme) ship with the repo; **tool skills** (the *how* — `github-source-control`, `github-projects`, `figma-design-system`, `figma-design-file`, the vendored `figma-use`) are installed per-project by setup scripts.

## Usage

Use this repository as a submodule so another project keeps `.agents` at a pinned revision and can update it deliberately.

From the **root** of the host repository:

```bash
git submodule add https://github.com/Byrde/agents.git .agents
git commit -m "Add .agents submodule"
```

**Cloning a host repo that already includes this submodule:** use `git clone --recurse-submodules <host-repo-url>`, or after a plain clone run `git submodule update --init --recursive`.

**Updating the submodule:** `git submodule update --remote .agents` follows the submodule's configured remote branch.

## Init

One-command bootstrap that installs rules and skills into your editor directories:

```bash
cd /your/project
.agents/scripts/init.sh
```

The script runs three steps:

1. **Rules** — copies `.agents/rules/` into `.cursor/rules/` and `.claude/rules/`
2. **Skills** — copies `.agents/skills/` into `.cursor/skills/` and `.claude/skills/`
3. **Auto-memory** — sets `autoMemoryEnabled: true` in `.claude/settings.json` (turning on Claude Code's built-in auto-memory, the default) and pins `autoMemoryDirectory` to the absolute path of `./memory` in `.claude/settings.local.json` (project-local storage; the content is git-tracked and shared with the team). `setup-memory.sh` turns the flag off (mempalace replaces it) and back on when uninstalled.

Optional setup (run separately when you want them):

- `.agents/scripts/setup-github.sh` — GitHub tool skills
- `.agents/scripts/setup-figma.sh` — Figma tool skills
- `.agents/scripts/setup-memory.sh` — persistent memory (mempalace) + the `memory` skill

**Uninstall.** Every setup script takes an `uninstall` subcommand that reverses exactly what its install wrote:

```bash
.agents/scripts/init.sh uninstall          # remove copied rules + skills, drop the auto-memory flag
.agents/scripts/setup-github.sh uninstall   # remove GitHub skills + MCP server
.agents/scripts/setup-figma.sh uninstall    # remove Figma skills (incl. figma-use) + MCP server
.agents/scripts/setup-memory.sh uninstall   # deregister mempalace MCP/hooks, remove skill+rule, re-enable auto-memory
```

`setup-memory.sh uninstall` preserves your palace data by default (it prompts before deleting `.mempalace/`, whose `chroma.sqlite3` is committed) and leaves the globally-installed `mempalace` package in place.

## Setup Tools

### GitHub

Configures opt-in GitHub tool skills and merges the GitHub MCP server into your editor's project config.

**Requires:** `gh` (GitHub CLI, authenticated), `jq`, `python3`

```bash
cd /your/project
.agents/scripts/setup-github.sh
```

Two opt-in capabilities — pick either, both, or neither:

- **`github-source-control`** — branches, pull requests, code review
- **`github-projects`** — work items, milestones, project board (requires `read:project` scope)

The script walks you through selecting your account, organisation/owner, repository, and (if installing `github-projects`) project board ID. It writes:

- `.agents/skills/github-source-control/SKILL.md` — per opt-in
- `.agents/skills/github-projects/SKILL.md` — per opt-in
- `.cursor/mcp.json` and `.mcp.json` — MCP server merged in

### Figma

Configures opt-in Figma tool skills, vendors Figma's official [`figma-use`](https://github.com/figma/mcp-server-guide/tree/main/skills/figma-use) skill into `skills/figma-use/`, and merges the Figma MCP server into your editor's project config.

**Requires:** `curl`, `git`, `jq`, `python3`, a [Figma Personal Access Token](https://www.figma.com/developers/api#access-tokens) with `file_content:read` and `projects:read` scopes

```bash
cd /your/project
.agents/scripts/setup-figma.sh
```

Two opt-in capabilities — pick either, both, or neither:

- **`figma-design-system`** — tokens, components, library publishing
- **`figma-design-file`** — one shared design file, organised by pages (flows, wireframes, visual design)

Both overlay on the vendored `figma-use` skill, which owns the Figma plugin-API mechanics. The script asks for your PAT, walks you through team/project selection, the Design System file (if installing `figma-design-system`), and the design file (if installing `figma-design-file`). Re-running the script refreshes `figma-use` from upstream main. It writes:

- `.agents/skills/figma-use/` — vendored from upstream (always refreshed)
- `.agents/skills/figma-design-system/SKILL.md` — per opt-in
- `.agents/skills/figma-design-file/SKILL.md` — per opt-in
- `.cursor/mcp.json` and `.mcp.json` — MCP server merged in

The Figma MCP server uses OAuth — authentication happens interactively through your editor on first use.

**Code map.** `figma-design-system` keeps a checked-in `figma-code-map.json` — a free stand-in for Figma Code Connect linking each Figma component to its code component. Its format is defined by `tools/figma-code-map.schema.json` (reference it via `"$schema"` for editor autocomplete). Validate it any time with:

```bash
cd /your/project
.agents/tools/figma-code-map-lint.sh        # defaults to ./figma-code-map.json
```

Pure `bash` + `jq`. Checks the file against the schema and against the project — component paths exist, code names are unique, node ids are well-formed — and warns about sibling source files that have no map entry. Exits non-zero on failure, so it drops cleanly into CI or a pre-commit hook.

### Memory

Installs [mempalace](https://github.com/milla-jovovich/mempalace) — a project-local, semantically searchable memory palace — initialises a palace for the project, registers its MCP server for both editors, wires up auto-save hooks, and installs the `memory` skill that teaches the agent how to use it (and how it relates to Claude's own built-in memory).

**Requires:** `python3` (< 3.14, for chromadb), `jq`

```bash
cd /your/project
.agents/scripts/setup-memory.sh
```

The script walks you through ignore patterns, palace initialisation (which indexes the project in one pass), the auto-save interval, MCP registration, and the `memory` skill. It writes:

- `.mempalace/` — project-local palace data
- `.mempalace/hooks/` — save and pre-compact hook scripts
- `.mempalaceignore` — ignore patterns for mining (node_modules, build output, binaries)
- `.agents/skills/memory/SKILL.md` — the `memory` tool skill (also mirrored into `.claude/skills/memory/` and `.cursor/skills/memory/`)
- `.cursor/mcp.json` and `.mcp.json` — MCP server merged in
- `.cursor/hooks.json` and `.claude/settings.local.json` — auto-save + pre-compact hooks
- `.claude/settings.json` — `autoMemoryEnabled: false` (mempalace replaces Claude Code's native auto-memory; `uninstall` restores it to `true`)

Re-run any time to upgrade mempalace or refresh configuration — on an already-initialised project it skips init and simply offers to re-mine. To re-index the project after large changes without the full walkthrough:

```bash
cd /your/project
.agents/scripts/setup-memory.sh mine
```

The `memory` skill is opt-in: it ships only once you've run this script. It covers when to recall prior context, what's worth saving (decisions, conventions, rationale, verbatim quotes), mining, and the split between project memory (mempalace) and Claude's cross-project memory.

### Doctor

Diagnoses the health of all MCP servers and skill installations configured by the setup scripts.

```bash
cd /your/project
.agents/scripts/doctor.sh
```

Reports per-capability presence (`github-source-control`, `github-projects`, `figma-design-system`, `figma-design-file`, `figma-use`, `memory`), MCP configuration, authentication, and server reachability. For memory it also checks the palace directory, mempalace importability, hooks, and a stdio handshake with the MCP server.