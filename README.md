# .agents

A library of self-contained, opinionated Claude Code skills for software development. Drop it into any repository as a submodule. Two kinds of skills compose freely via shared verb+noun vocabulary: **practice skills** (the *what* — develop, plan, architect, design, test, create-readme) ship with the repo; **tool skills** (the *how* — `github-projects`, `figma-design-system`, `figma-design-file`, the vendored `figma-use`) are installed per-project by setup scripts. Some capabilities are always-on **rules** instead of opt-in skills — notably `workspace` (multi-repo routing) and `github-source-control` (branches/PRs/review) — installed automatically by `init.sh`.

## Usage

Use this repository as a submodule so another project keeps `.agents` at a pinned revision and can update it deliberately.

From the **root** of the host repository:

```bash
git submodule add https://github.com/Byrde/agents.git .agents
git commit -m "Add .agents submodule"
```

**Cloning a host repo that already includes this submodule:** use `git clone --recurse-submodules <host-repo-url>`, or after a plain clone run `git submodule update --init --recursive`.

**Updating the submodule:** `git submodule update --remote .agents` follows the submodule's configured remote branch.

### Single-Repo or Multi-Repo Workspace

`.agents` works whether you open your agent in a single repository or in a folder that sits above several repos. `init.sh` figures out which and sets it up — no separate step, nothing to declare up front.

- **Single repo (`mono`).** `.agents` is a submodule at the repo root and you work from that root. Tool skills + the manifest stage in the checkout (`.agents/skills/`, `.agents/.manifest.local.yml`).

- **Multi-repo workspace (`multi`).** One `.agents` lives at a folder above several sibling repositories, and you open your agent at that folder to work across all of them. The always-on [workspace rule](#workspace) reads a generated map (`.workspace.agents.json` at the context root) to learn what each repo is and routes every task to the right one. (If you instead `cd` into one repo to configure a tool skill scoped to it, that repo's rendered skills + manifest stage in its own `<repo>/.byrde/` so repos never clobber each other.)

`init.sh` auto-detects the flavour (multiple sibling repos ⇒ `multi`, else `mono`), writes `.workspace.agents.json`, and installs the workspace rule. Re-running `init.sh` refreshes the map (and preserves a `mode` you've hand-edited). To force the flavour, set `BYRDE_WORKSPACE_MODE=mono|multi` or edit `mode` in the map.

## Init

One-command bootstrap that installs rules and skills into your editor directories:

```bash
cd /your/project
.agents/scripts/init.sh
```

The script runs these steps:

1. **Rules** — copies `.agents/rules/` into `.cursor/rules/` and `.claude/rules/` (includes the always-on [workspace rule](#workspace))
2. **Skills** — copies `.agents/skills/` into `.cursor/skills/` and `.claude/skills/`
3. **Workspace map** — generates `.workspace.agents.json` at the project root, auto-detecting mono vs multi-repo (see [Workspace](#workspace)); gitignored
4. **Auto-memory** — sets `autoMemoryEnabled: true` in `.claude/settings.json` (turning on Claude Code's built-in auto-memory, the default) and pins `autoMemoryDirectory` to the absolute path of `./memory` in `.claude/settings.local.json` (project-local storage; the content is git-tracked and shared with the team). `setup-memory.sh` turns the flag off (mempalace replaces it) and back on when uninstalled.

Optional setup (run separately when you want them):

- `.agents/scripts/setup/setup-github-project.sh` — pin a GitHub project board (source-control + MCP are set up by `init.sh`)
- `.agents/scripts/setup/setup-figma.sh` — Figma tool skills
- `.agents/scripts/setup/setup-memory.sh` — persistent memory (mempalace) + the `memory` skill

**Uninstall.** Every setup script takes an `uninstall` subcommand that reverses exactly what its install wrote:

```bash
.agents/scripts/init.sh uninstall            # remove copied rules + skills, the workspace map, drop the auto-memory flag
.agents/scripts/setup/setup-github-project.sh uninstall  # remove the github-projects skill
.agents/scripts/setup/setup-figma.sh uninstall    # remove Figma skills (incl. figma-use) + MCP server
.agents/scripts/setup/setup-memory.sh uninstall   # deregister mempalace MCP/hooks, remove skill+rule, re-enable auto-memory
```

## Setup Tools

### GitHub

GitHub splits into two pieces with very different shapes:

**Source control** (branches, PRs, review, merge) needs **no repo configuration**. The GitHub MCP server is account-wide — it works across every repo you can access — so there's nothing repo-specific to pin. `init.sh` handles it automatically: it installs the always-on `github-source-control` **rule** (`.claude/rules/`, `.cursor/rules/`) and registers the account-wide GitHub MCP in `.mcp.json` / `.cursor/mcp.json` whenever the workspace map has a `github.com` remote. The rule resolves the *target* repo per task from `.workspace.agents.json` — no single-repo pin, works across the whole workspace.

Auth: GitHub's OAuth doesn't support dynamic client registration, so the MCP authenticates with a token in an `Authorization` header — GitHub's documented fallback. How the token gets there depends on the editor:

- **Claude Code** — zero setup. `init.sh` configures a `headersHelper` (`.agents/scripts/mcp/gh-mcp-headers.sh`) that Claude Code runs on each connection to pull the token live from `gh auth token`. Nothing is stored on disk and there's no env var to set — just be logged in (`gh auth login`). For SAML-SSO orgs, ensure your `gh` login is authorized for the org.
- **Cursor** — has no `headersHelper`, so it gets a static `"Authorization": "Bearer ${GITHUB_PERSONAL_ACCESS_TOKEN}"` header (expanded at load time). Cursor users export that var: `export GITHUB_PERSONAL_ACCESS_TOKEN="$(gh auth token)"`.

(The helper falls back to `$GITHUB_PERSONAL_ACCESS_TOKEN` if `gh` isn't available, so a PAT works everywhere too.)

**Projects** (work items, milestones, board state) is the one piece that needs a pin — a project board (owner + board number) can't be auto-detected — so it stays an explicit, opt-in step:

**Requires:** `gh` (GitHub CLI, authenticated, `read:project` scope), `jq`, `python3`

```bash
cd /your/workspace
.agents/scripts/setup/setup-github-project.sh            # pin a board + install the github-projects skill
.agents/scripts/setup/setup-github-project.sh uninstall  # remove the github-projects skill
```

It walks you through your account, owner, the repo the board mainly tracks, and the board ID; writes `skills/github-projects/SKILL.md` (mirrored into `.claude/`/`.cursor/`); and ensures the GitHub MCP is registered. The MCP itself is shared with source-control and is managed by `init.sh` — `setup-github-project.sh uninstall` leaves it in place.

### Figma

Configures opt-in Figma tool skills, vendors Figma's official [`figma-use`](https://github.com/figma/mcp-server-guide/tree/main/skills/figma-use) skill into `skills/figma-use/`, and merges the Figma MCP server into your editor's project config.

**Requires:** `curl`, `git`, `jq`, `python3`, a [Figma Personal Access Token](https://www.figma.com/developers/api#access-tokens) with `file_content:read` and `projects:read` scopes

```bash
cd /your/project
.agents/scripts/setup/setup-figma.sh
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
.agents/scripts/setup/setup-memory.sh
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
.agents/scripts/setup/setup-memory.sh mine
```

The `memory` skill is opt-in: it ships only once you've run this script. It covers when to recall prior context, what's worth saving (decisions, conventions, rationale, verbatim quotes), mining, and the split between project memory (mempalace) and Claude's cross-project memory.

### Doctor

Diagnoses the health of all MCP servers and skill installations configured by the setup scripts.

```bash
cd /your/project
.agents/scripts/doctor.sh
```

Reports per-capability presence (`github-projects`, `figma-design-system`, `figma-design-file`, `figma-use`, `memory`), MCP configuration, authentication, and server reachability. For memory it also checks the palace directory, mempalace importability, hooks, and a stdio handshake with the MCP server.