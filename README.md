# .agents

A library of self-contained, opinionated agent skills and rules for software development, adapted on install to Claude Code, Cursor, OpenAI Codex, GitHub Copilot, Google Antigravity and OpenCode. Drop it into any repository as a submodule. Two kinds of skills compose freely via shared verb+noun vocabulary ([`skills/CAPABILITIES.md`](skills/CAPABILITIES.md)): **practice skills** (the *what* — `plan`, `architect`, `design`, `develop`, `test`, `debug`, `review`, `quick-edit`, `docs`) ship with the repo. **Tool skills** (the *how* — `github-projects`, `jira`, `google-analytics`, `figma`, the vendored `figma-use`, `model-router`) are installed per-project by setup scripts. Some capabilities are always-on **rules** instead of opt-in skills — notably `workspace` (multi-repo routing) and `github-source-control` (branches/PRs/review) — installed automatically by `init.sh`.

## What's included

### Rules

Always on. `init.sh` renders each one into every selected harness (see [Harnesses](#harnesses)).

| Rule | What it covers |
|---|---|
| [`global`](rules/global.md) | Project-wide baseline. The lead rule: re-injected in full during long sessions (see [Rules re-injection](#rules-re-injection)) |
| [`development`](rules/development.md) | Architectural standards — Lite DDD modular monolith by default |
| [`github-source-control`](rules/github-source-control.md) | Branches, pull requests and code review through the account-wide GitHub MCP server |
| [`workspace`](rules/workspace.md) | Finds which repository a task belongs to in a multi-repo workspace, and works inside it |
| [`memory`](rules/memory.md) | When to write memory, and what belongs in it (pairs with Claude Code's built-in auto-memory) |
| [`technical-writing`](rules/technical-writing.md) | ASD-STE100 Simplified Technical English for docs, work items and specs |

### Practice skills

Ship with the repo. `init.sh` makes them visible to every selected harness.

| Skill | Invoke it before you… |
|---|---|
| [`plan`](skills/plan/SKILL.md) | create, split or re-scope a work item |
| [`architect`](skills/architect/SKILL.md) | change a module boundary, add a dependency, or decide build-vs-buy |
| [`design`](skills/design/SKILL.md) | build or change a screen, flow or component |
| [`develop`](skills/develop/SKILL.md) | make the first edit of a change that will open a pull request (TDD, one slice at a time) |
| [`test`](skills/test/SKILL.md) | claim an implementation meets its acceptance criteria |
| [`debug`](skills/debug/SKILL.md) | fix anything reported as broken, even when the fix looks obvious (reproduce, prove, encode as a test) |
| [`review`](skills/review/SKILL.md) | review code, a diff, a branch or a pull request (findings ranked by severity) |
| [`quick-edit`](skills/quick-edit/SKILL.md) | make a small, fully specified edit that opens no pull request |
| [`docs`](skills/docs/SKILL.md) | write or substantially rewrite prose for people: a README, a guide, a changelog |

### Tool skills

Opt-in, one setup script each (see [Setup Tools](#setup-tools)). Each renders its skill from a template in [`tools/`](tools/) (`figma-use` is vendored from upstream instead) and registers the MCP server it needs, if any.

| Skill | Setup script | Owns | MCP server |
|---|---|---|---|
| `github-projects` | `setup-github-project.sh` | Work items, milestones, board state on a GitHub project board | GitHub (shared with source control) |
| `jira` | `setup-jira.sh` | Work items and the project board in Jira | Atlassian Remote MCP |
| `google-analytics` | `setup-google-analytics.sh` | GA4 reporting queries | Google `analytics-mcp` |
| `figma` + `figma-use` | `setup-figma.sh` | Design tokens, components and design work in one Figma file | Figma |
| `model-router` | `setup-model-router.sh` | Which model handles which task (OpenCode only) | — |

Pick one work-item tracker per project: `github-projects` and `jira` claim the same operations.

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

- **Multi-repo workspace (`multi`).** One `.agents` lives at a folder above several sibling repositories, and you open your agent at that folder to work across all of them. The always-on [workspace rule](#rules) reads a generated map (`.workspace.agents.json` at the context root) to learn what each repo is and routes every task to the right one. (If you instead `cd` into one repo to configure a tool skill scoped to it, that repo's rendered skills + manifest stage in its own `<repo>/.byrde/` so repos never clobber each other.)

`init.sh` auto-detects the flavour (multiple sibling repos ⇒ `multi`, else `mono`), writes `.workspace.agents.json`, and installs the workspace rule. Re-running `init.sh` refreshes the map (and preserves a `mode` you've hand-edited). To force the flavour, set `BYRDE_WORKSPACE_MODE=mono|multi` or edit `mode` in the map.

## Init

One-command bootstrap that installs rules, skills, MCP servers and hooks, adapted to each agent harness you choose:

```bash
cd /your/project
.agents/scripts/init.sh                            # OpenCode only (asks first on a terminal)
.agents/scripts/init.sh --harness opencode,claude  # these harnesses, no question
.agents/scripts/init.sh --harness all              # every harness
.agents/scripts/init.sh uninstall                  # remove everything init installed
```

**The default is OpenCode and nothing else.** On a terminal, init shows the harness list with OpenCode ticked, and Enter accepts it. A non-interactive run (CI, a script, piped stdin) installs for OpenCode without asking. Once a choice is saved, it becomes the default for later runs.

### Init parameters

| Parameter | Meaning |
|---|---|
| `--harness LIST` | Harnesses to install and adapt assets for, comma-separated. Names: `opencode`, `claude`, `cursor`, `codex`, `copilot`, `antigravity`, or `all`. Numbers select by position in `claude cursor codex copilot antigravity opencode` (1–6). Also spelled `--harness=LIST` or `--harnesses LIST`. Skips the question. |
| `uninstall` (alias `remove`) | Removes rules, skills, the GitHub MCP server, hooks and settings from **every** harness, not only the selected ones. Tool skills from `setup-*.sh` stay; uninstall those with their own scripts. |
| `-h`, `--help`, `help` | Prints usage. |

| Environment variable | Meaning |
|---|---|
| `BYRDE_HARNESSES` | Same as `--harness`, for one run. The flag wins when both are set. The setup scripts read it too. |
| `BYRDE_WORKSPACE_MODE` | `mono` or `multi`: force the workspace flavour instead of auto-detecting it (see [Single-Repo or Multi-Repo Workspace](#single-repo-or-multi-repo-workspace)). |
| `BYRDE_RULES_REINJECT_EVERY` | Re-inject the rules every N tool calls (default `12`, `0` turns it off). Read at run time by the hooks and the OpenCode plugin, not by init. |

Which harnesses are used, in order of precedence: `--harness` > `BYRDE_HARNESSES` > the answer to the question (terminal only) > `harnesses` saved in `.workspace.agents.json` > `opencode`.

The choice is saved as `harnesses` in `.workspace.agents.json`. Re-runs and every `setup-*.sh` script use it. Re-running with fewer harnesses removes what the dropped ones had. For example, `init.sh --harness opencode` after `--harness all` removes the Claude Code, Cursor, Codex, Copilot and Antigravity files.

### What init does

1. **Harnesses** — resolves the harnesses as described above
2. **Workspace map** — generates `.workspace.agents.json` at the project root, auto-detecting mono vs multi-repo (see [Single-Repo or Multi-Repo Workspace](#single-repo-or-multi-repo-workspace)). Gitignored
3. **Rules** — renders each `.agents/rules/*.md` into each harness's format (see [Rules](#rules)) — see [Harnesses](#harnesses)
4. **Skills** — makes `.agents/skills/` visible to each harness
5. **Auto-memory** (Claude Code only) — sets `autoMemoryEnabled: true` in `.claude/settings.json` (turning on Claude Code's built-in auto-memory, the default) and pins `autoMemoryDirectory` to the absolute path of `./memory` in `.claude/settings.local.json` (project-local storage, git-tracked and shared with the team).
6. **Hooks** — writes two hooks for each harness that has them: an allow-all pre-tool hook that approves every tool call, and a post-tool hook that re-injects the rules (see below)

### Harnesses

Every asset has one source, and each harness gets it in its own files and format. The adapters live in [`scripts/lib/harness.sh`](scripts/lib/harness.sh):

| | Rules | Skills | MCP servers | Hooks |
|---|---|---|---|---|
| **Claude Code** | `.claude/rules/*.md` | `.claude/skills/` | `.mcp.json` | `.claude/settings.json` |
| **Cursor** | `.cursor/rules/*.mdc` (`alwaysApply`) | `.agents/skills/` | `.cursor/mcp.json` | `.cursor/hooks.json` |
| **OpenAI Codex** | one fenced section per rule in `AGENTS.md` | `.agents/skills/` | `.codex/config.toml` | `.codex/hooks.json` |
| **GitHub Copilot** | `.github/instructions/*.instructions.md` (`applyTo: "**"`) | `.agents/skills/` | `.vscode/mcp.json` | `.github/hooks/byrde-agents.json` |
| **Google Antigravity** | `.agents/rules/*.md`, read in place | `.agents/skills/` | `.agents/mcp_config.json` | — |
| **OpenCode** | sections in `AGENTS.md` (shared with Codex) | `.agents/skills/` | `.opencode/opencode.json` | plugin `.opencode/plugins/byrde-agents.js` |

**`.agents/` is shared ground.** Cursor, Codex, Copilot and Antigravity all read `.agents/skills/` natively, and Antigravity reads `.agents/rules/` too. That folder is this checkout, so they use the source in place and nothing is copied twice. Only Claude Code gets a copy. Rule sources carry `description` and `trigger: always_on` frontmatter for this reason. The other formats are rendered from them, so there is no hand-kept `.mdc` twin.

Things to know:

- **Codex** loads `.codex/` only in a trusted project, and asks you to trust each hook once (`/hooks`). Your own text in `AGENTS.md` is kept. Only the `<!-- byrde-agents:rule … -->` sections are rewritten. Cursor, Copilot and Antigravity read `AGENTS.md` as well, so selecting Codex with them loads the rules twice in those tools.
- **Tokens.** Only Claude Code can fetch the GitHub token live (`headersHelper`). Cursor, Codex and Copilot read it from `GITHUB_PERSONAL_ACCESS_TOKEN`. Antigravity cannot read the environment, so servers that need a token are skipped for it rather than written with a secret.
- **Antigravity hooks**: none. Its `PostToolUse` cannot add context.
- **Copilot**: `.vscode/mcp.json` is for VS Code. Copilot CLI reads `.mcp.json`, which exists when Claude Code is selected too. The coding agent takes MCP config from repository settings, not from a file.
- **Claude Code only**: auto-memory, `permissions.defaultMode`, the MCP approval, and workspace trust. They are removed when Claude Code is dropped.

### OpenCode

OpenCode is configured by files under `.opencode/`, so a host's own root `opencode.json` is never touched. Works with OpenCode 1.18.29+ and 2.x.

**Settings — `.opencode/opencode.json`.** Merged, never replaced: `$schema`, `"permission": "allow"`, and one `mcp` entry per server (`type: "remote"` with `{env:VAR}` headers, or `type: "local"` with a `command` array). The permission is set only when the file has none. If you wrote your own rules, they stay, and the plugin's allow-all hook approves what they leave as `ask` (a `deny` still wins). Ownership is recorded, so uninstall takes back only what it gave.

**Rules — `AGENTS.md`.** OpenCode 2 ignores the `instructions` key and reads only `AGENTS.md`, so the rules go there for both versions. The sections are shared with Codex: they stay while either one is selected.

**Hooks — the `byrde-agents` plugin.** OpenCode has no command hooks; plugins are its hooks. [`scripts/hooks/opencode/byrde-agents.js`](scripts/hooks/opencode/byrde-agents.js) is copied to `.opencode/plugins/` and implements both plugin APIs from one file (OpenCode 2 `setup(ctx)`, OpenCode 1 `server()`), with no dependencies:

| Hook | OpenCode 2 | OpenCode 1 | What it does |
|---|---|---|---|
| Rules re-injection | `tool.hook("execute.after")` | `tool.execute.after` | Every `BYRDE_RULES_REINJECT_EVERY` tool calls (default 12), appends the lead rule to the tool result the model reads |
| Rules through compaction | `session.hook("compaction")` | `experimental.session.compacting` | Gives the lead rule to the compaction request, so the summary that replaces the history keeps it |
| Allow-all | `permission.hook("evaluate")` | `permission.ask` | Turns `ask` into `allow` |
| Model routing | `session.hook("context")` | — | With the [model router](#model-router) set up, lists the routed tasks in the main agent's system prompt so it delegates by itself |

Its settings live in `.opencode/byrde-agents.json`: the rules folder and allow-all (from `init.sh`). Re-run `init.sh` after updating `.agents` to refresh the copied plugin; `doctor.sh` warns when it is out of date.

OpenCode also reads `.claude/skills/`. With Claude Code selected too, it finds each practice skill in two places.

### Rules re-injection

Rules load once, at session start. Nothing re-asserts them, so they lose to the most recent tool result as a session grows, and compliance decays without anyone noticing.

[`scripts/hooks/reinject-rules.sh`](scripts/hooks/reinject-rules.sh) runs after each tool call (**`PostToolUse`**) and re-injects the rules every 12 tool calls. `--harness` selects the answer shape: Claude Code and Codex read `hookSpecificOutput.additionalContext`, Cursor reads `additional_context`, and Copilot reads `additionalContext`. The trigger is a tool call rather than a user message on purpose: the model works through many tool calls between two of your messages, and that output is what buries the rules. The stream that buries them brings them back.

It injects the **short form** — `global.md` in full, plus the names of the other rule files. Repeating every rule file on a tool-call cadence would eat the context the rules are meant to protect.

Set the cadence with `BYRDE_RULES_REINJECT_EVERY` (default `12`, `0` disables).

One trap worth knowing if you write your own hook: `PostToolUse` **ignores stdout**. The model only reads `hookSpecificOutput.additionalContext`, so the hook answers with JSON. `UserPromptSubmit` is the opposite — there, stdout *is* the injection. Both shapes are handled, so an install wired the old way keeps working until you re-run `init.sh`.

Optional setup (run separately when you want them, see [Setup Tools](#setup-tools)):

- `.agents/scripts/setup/setup-github-project.sh` — pin a GitHub project board (source-control + MCP are set up by `init.sh`)
- `.agents/scripts/setup/setup-jira.sh` — pin a Jira site + project
- `.agents/scripts/setup/setup-google-analytics.sh` — pin a GA4 property
- `.agents/scripts/setup/setup-figma.sh` — the Figma tool skill
- `.agents/scripts/setup/setup-model-router.sh` — route OpenCode tasks to the best-suited model

**Uninstall.** Every setup script takes an `uninstall` subcommand that reverses exactly what its install wrote:

```bash
.agents/scripts/init.sh uninstall            # remove rules, skills and hooks from every harness, the workspace map, the auto-memory flag
.agents/scripts/setup/setup-github-project.sh uninstall  # remove the github-projects skill
.agents/scripts/setup/setup-jira.sh uninstall    # remove the jira skill + Atlassian MCP server
.agents/scripts/setup/setup-google-analytics.sh uninstall  # remove the google-analytics skill + MCP server
.agents/scripts/setup/setup-figma.sh uninstall    # remove Figma skills (incl. figma-use) + MCP server
.agents/scripts/setup/setup-model-router.sh uninstall  # remove the route subagents, commands, cache and skill (keeps your config)
```

## Setup Tools

### GitHub

GitHub splits into two pieces with very different shapes:

**Source control** (branches, PRs, review, merge) needs **no repo configuration**. The GitHub MCP server is account-wide — it works across every repo you can access — so there's nothing repo-specific to pin. `init.sh` handles it automatically: it installs the always-on `github-source-control` **rule** and registers the account-wide GitHub MCP for each selected harness whenever the workspace map has a `github.com` remote. The rule resolves the *target* repo per task from `.workspace.agents.json` — no single-repo pin, works across the whole workspace.

Auth: GitHub's OAuth doesn't support dynamic client registration, so the MCP authenticates with a token in an `Authorization` header — GitHub's documented fallback. How the token gets there depends on the editor:

- **Claude Code** — zero setup. `init.sh` configures a `headersHelper` (`.agents/scripts/mcp/gh-mcp-headers.sh`) that Claude Code runs on each connection to pull the token live from `gh auth token`. Nothing is stored on disk and there's no env var to set — just be logged in (`gh auth login`). For SAML-SSO orgs, ensure your `gh` login is authorized for the org.
- **Cursor, Copilot, Codex** — have no `headersHelper`, so they read the token from the environment: an `Authorization: Bearer ${env:GITHUB_PERSONAL_ACCESS_TOKEN}` header (Cursor, VS Code), or `bearer_token_env_var` (Codex). Export that var: `export GITHUB_PERSONAL_ACCESS_TOKEN="$(gh auth token)"`.
- **Antigravity** — cannot read the environment in its MCP config, so the GitHub server is not registered for it.

(The helper falls back to `$GITHUB_PERSONAL_ACCESS_TOKEN` if `gh` isn't available, so a PAT works everywhere too. It resolves `gh` and `jq` by absolute path rather than through `PATH`, because an editor launched from Finder or the Dock inherits a `PATH` that holds no Homebrew.)

### Which GitHub account a workspace uses

`gh auth token` returns whichever account is **active on the machine**. If you work across several client organisations, each with its own GitHub account, that means the last account you switched to leaks into every workspace — and a valid token for the wrong account looks exactly like success.

So a workspace can name its account. Resolution order:

1. `$BYRDE_GH_ACCOUNT` — explicit override
2. `githubAccount` in `.workspace.agents.json` — this workspace's account
3. the machine-active `gh` account — the default

Ranks 1 and 2 are **binding**. If a workspace names an account and no token for it is available, the helper fails and says which account it needed. It does not fall back, because falling back is the leak. Rank 3 keeps a single-account setup working with no configuration.

```json
{ "mode": "multi", "contextRoot": ".", "repos": [ … ], "githubAccount": "your-client-login" }
```

`init.sh` preserves `githubAccount` when it refreshes the map, the same way it preserves `purpose`.

Claude Code also needs the server **approved**, not just registered: a server declared in a project `.mcp.json` stays untrusted until it is listed in `enabledMcpjsonServers`, and an unapproved server never loads. `init.sh` writes that approval into `.claude/settings.json` alongside the registration. Skipping it is how you get `Incompatible auth server: does not support dynamic client registration` — the editor never reaches the header path above and falls back to the OAuth handshake this section explains GitHub cannot complete. The message blames auth while the token is fine.

**And the approval only counts once the workspace is trusted.** Claude Code skips a project's settings wholesale until then, so the approval is inert and the token helper is never run:

```
MCP server 'github': headersHelper not run — this workspace has no persisted trust;
accept the trust dialog here once interactively, or set
projects["<root>"].hasTrustDialogAccepted in ~/.claude.json.
```

`init.sh` takes the second remedy, because the first cannot happen in a non-interactive session. It sets `hasTrustDialogAccepted` for this workspace, and only when the workspace has a GitHub remote — so a folder that needs no MCP is not trusted as a side effect.

Trust is **not** MCP-specific: it makes Claude Code honour this project's `.claude/settings.json` generally. That is a real widening of what the installer does, so it is announced on install and `init.sh uninstall` gives it back. It gives back **only what init granted** — if you accepted the trust dialog yourself, an uninstall leaves your decision alone. The grant is recorded as `workspace-trust` in `.manifest.local.yml`.

`init.sh` never creates `~/.claude.json`, and never rewrites it when it cannot be parsed. That file holds every project on the machine and the account block, so a corrupt one is left untouched and the MCP simply stays unregistered.

To diagnose any of this, ask the tool rather than guessing — `claude mcp get github` names the cause and the remedy.

**Projects** (work items, milestones, board state) is the one piece that needs a pin — a project board (owner + board number) can't be auto-detected — so it stays an explicit, opt-in step:

**Requires:** `gh` (GitHub CLI, authenticated, `read:project` scope), `jq`, `python3`

```bash
cd /your/workspace
.agents/scripts/setup/setup-github-project.sh            # pin a board + install the github-projects skill
.agents/scripts/setup/setup-github-project.sh uninstall  # remove the github-projects skill
```

It walks you through your account, owner, the repo the board mainly tracks, and the board ID. It then writes `skills/github-projects/SKILL.md`, made visible to each selected harness. It also ensures the GitHub MCP is registered. The MCP itself is shared with source-control and is managed by `init.sh` — `setup-github-project.sh uninstall` leaves it in place.

### Figma

Configures the opt-in `figma` tool skill, vendors Figma's official [`figma-use`](https://github.com/figma/mcp-server-guide/tree/main/skills/figma-use) skill into `skills/figma-use/`, and merges the Figma MCP server into your editor's project config.

**Requires:** `curl`, `git`, `jq`, `python3`, a [Figma Personal Access Token](https://www.figma.com/developers/api#access-tokens) with `file_content:read` and `projects:read` scopes

```bash
cd /your/project
.agents/scripts/setup/setup-figma.sh
```

**One skill, one file.** `figma` owns the whole design surface: the reusable components and tokens live on a `Components` page, design work lives on whatever other pages the work needs. No separate design-system library file, no prescribed page taxonomy, no Cover/Archive ceremony — components are used locally in the same file, and publishing is only needed when something outside that file consumes them.

It overlays on the vendored `figma-use` skill, which owns the Figma plugin-API mechanics. The script asks for your PAT and walks you through team, project, and file selection. Re-running it refreshes `figma-use` from upstream main and clears out the retired `figma-design-system` / `figma-design-file` skills if an older install left them behind. It writes:

- `.agents/skills/figma-use/` — vendored from upstream (always refreshed)
- `.agents/skills/figma/SKILL.md`
- the MCP config of each selected harness — Figma server merged in

The Figma MCP server uses OAuth — authentication happens interactively through your editor on first use.

**Code map.** `figma` keeps a checked-in `figma-code-map.json` — a free stand-in for Figma Code Connect linking each Figma component to its code component. Its format is defined by `tools/figma-code-map.schema.json` (reference it via `"$schema"` for editor autocomplete). Validate it any time with:

```bash
cd /your/project
.agents/tools/figma-code-map-lint.sh        # defaults to ./figma-code-map.json
```

Pure `bash` + `jq`. Checks the file against the schema and against the project — component paths exist, code names are unique, node ids are well-formed — and warns about sibling source files that have no map entry. Exits non-zero on failure, so it drops cleanly into CI or a pre-commit hook.

### Jira

Configures the opt-in `jira` tool skill against a Jira site + project, and registers Atlassian's official Remote MCP server. Use it instead of `github-projects` when the team tracks work in Jira.

**Requires:** `jq`, `python3`

```bash
cd /your/workspace
.agents/scripts/setup/setup-jira.sh            # pin a site + project, install the jira skill
.agents/scripts/setup/setup-jira.sh uninstall  # remove the skill + MCP server
```

It asks for the Jira site and project key, with light format checks only (there is no Jira CLI to validate against). Either can be left blank and pinned later. It writes:

- `skills/jira/SKILL.md`, made visible to each selected harness
- the MCP config of each selected harness — Atlassian server (`https://mcp.atlassian.com/v1/sse`) merged in

No secrets on disk: the Atlassian MCP uses OAuth 2.1 with dynamic client registration, so your editor runs the consent flow on first use. The skill resolves the cloud ID live.

### Google Analytics

Configures the opt-in `google-analytics` tool skill against a GA4 property, and registers Google's official `analytics-mcp` server (read-only reporting, run through `pipx`).

**Requires:** `gcloud` (authenticated), `pipx`, `jq`, `python3`

```bash
cd /your/workspace
.agents/scripts/setup/setup-google-analytics.sh            # pin a GA4 property, install the skill
.agents/scripts/setup/setup-google-analytics.sh uninstall  # remove the skill + MCP server
```

It establishes Application Default Credentials with the `analytics.readonly` scope through `gcloud auth application-default login` (asking for your OAuth client JSON when it needs one), offers to enable the required APIs, then asks for the Google Cloud quota project and the GA4 property. The property can be left blank and pinned later. It writes:

- `skills/google-analytics/SKILL.md`, made visible to each selected harness
- the MCP config of each selected harness — `analytics-mcp` merged in

No secrets on disk: `analytics-mcp` finds the credentials in gcloud's ADC store, so the MCP config carries only `GOOGLE_PROJECT_ID`.

### Model router

Routes each kind of task to the model that suits it best, in OpenCode 2. Tasks and [practice skills](#practice-skills) match one to one: the skill is the method, the task picks the model that runs it. You and the agent decide what matters for each task (reasoning, coding, speed, cost, …). The router scores every model your providers offer against public benchmarks and assigns one model per task. Scoring runs only when you ask for it, never on each request.

**Requires:** OpenCode 2 selected by `init.sh`, `jq`, `python3`, `curl`, and an [Artificial Analysis](https://artificialanalysis.ai/) API key (free tier) in `ARTIFICIAL_ANALYSIS_API_KEY`.

```bash
cd /your/project
.agents/scripts/setup/setup-model-router.sh                     # starter config + model-router skill
.agents/scripts/setup/setup-model-router.sh evaluate            # score the models, assign one per task
.agents/scripts/setup/setup-model-router.sh evaluate --offline  # re-score from the last download (after changing weights)
.agents/scripts/setup/setup-model-router.sh show                # print the current assignments
.agents/scripts/setup/setup-model-router.sh uninstall           # remove the subagents, commands, cache and skill
```

**Routing is implicit.** Each task becomes an OpenCode subagent, `.opencode/agents/route-<task>.md`, pinned to its model and described by when to use it. The main agent sees those descriptions in its subagent tool. The `byrde-agents` plugin also adds a routing table to its system prompt. So a request that matches a task goes to that task's model without being named. The child session runs on the pinned model, while the main session keeps its own. `/route-<task>` commands force a task by hand (set `"commands": false` to skip them). The subagents have no prompt of their own, so they keep OpenCode's default system prompt.

**Skills and tasks stay in step, both ways.** Install starts with one task per practice skill. Every install and `evaluate` re-runs the sync. A new practice skill gets a task: curated weights for the shipped skills, seeded ones (flagged for tuning) for others. A task with no practice skill is reported, and the `model-router` skill helps you write the skill or drop the task. To leave a skill unrouted, list it in `skipSkills`. `doctor.sh` warns when the two drift apart. A routed subagent follows its skill: the routing table tells the main agent to delegate instead of invoking the skill itself.

**Configure with the agent.** The `model-router` skill runs the conversation: which tasks deserve their own model, which dimensions matter for each and by how much, hard limits, and the provider order. It edits `.opencode/model-router.json`:

| Key | Meaning |
|---|---|
| `providers` | OpenCode provider IDs to evaluate, in priority order. Only their models are scored. When several providers serve the same model, the first one listed wins. |
| `tasks` | Per task: `skill`, `description`, `when` (the delegation trigger), `profile`, optional `weights` that override the profile's, `require` and `minCoverage` |
| `skipSkills` | Practice skills that deliberately get no task |
| `dimensions` | Benchmark metrics and their weights, e.g. `coding`: `coding_index`, `livecodebench`, `scicode` |
| `profiles` | Dimension weights per kind of work, shared by tasks: `deep` (plan, architect, design, review), `build` (develop, test, debug), `fast` (quick-edit), `write` (docs) |
| `requirements` | Hard limits for every task: `tools`, `minContext`, `input` (e.g. `["image"]`) |
| `aliases` | Map a model the benchmarks list under another name, or `null` to skip it |
| `exclude` | Glob patterns for models never to pick |
| `evaluation` | Written by `evaluate`: assignments, per-model dimension scores, runner-ups, unmatched models |

**How a model is scored.**
- **Identity.** The same model under different providers is recognised through the `canonical_model_id` in the models.dev catalogue OpenCode uses. For example, `github-copilot/claude-sonnet-5.5` and `openrouter/anthropic/claude-sonnet-5.5` are both `anthropic/claude-sonnet-5-5`.
- **Benchmark match.** That ID is matched to an Artificial Analysis entry. A model with no match is listed, not guessed; settle it with `aliases`.
- **Metrics.** Each metric becomes a percentile against every model Artificial Analysis lists, so adding a provider doesn't shift the other scores. Price and latency count lower as better.
- **Profiles.** Tasks that need the same thing share a weight profile, so they run on the same model. Otherwise a gap of a few thousandths between two frontier models, which is benchmark noise, would split them. A task overrides its profile only where its needs really differ: debug weighs long context more, for logs and traces.
- **Dimensions and tasks.** A dimension is the weighted mean of the metrics the model has. A task score is the weighted mean of its profile's dimensions, with the task's own weights on top, and a dimension with no data counts as the median (0.5), so missing data neither helps nor sinks a model. Each assignment reports its coverage: the share of the weight that rests on real data.
- **Effort.** Reasoning effort is scored per variant. AA's `-high` and `-low` entries map to OpenCode's `#high` and `#low`, and the winning effort is pinned in the subagent's model.

**Commit** `.opencode/model-router.json`, `.opencode/agents/` and `.opencode/commands/` so the team shares the routing. Raw API responses are cached in `.opencode/.model-router/`, which ignores itself. A teammate who lacks a provider in the list gets a subagent pinned to a model they cannot call. `doctor.sh` flags that, and flags an evaluation older than 45 days.

**No secrets on disk.** The API key is read from the environment and sent on curl's stdin. OpenCode's model list includes provider settings, API keys among them; only model IDs, variants, capabilities and limits are kept from it.

Benchmark data: [Artificial Analysis](https://artificialanalysis.ai/). Their free API requires attribution, so reports and generated files credit it.

### Doctor

Diagnoses the health of all MCP servers and skill installations configured by the setup scripts.

```bash
cd /your/project
.agents/scripts/doctor.sh
```

Reports, for each selected harness, whether its rules, skills and hooks are installed, and checks the workspace map. Then, for each tool that is set up (recorded in `.manifest.local.yml`), it reports the skill, the MCP configuration per harness, authentication, and server reachability: GitHub (source control and projects), Figma (`figma`, `figma-use`), Google Analytics and Jira. For the model router, it checks the config, the age of the evaluation, that each subagent is pinned to its assigned model, and that the assigned models are usable on this machine. A tool you never installed, or uninstalled, is left out of the report.

### Tests

Offline suites cover the installer itself, and live tests verify that the hooks work inside a real Claude Code session — that the session runs them mid-loop, and that what they emit reaches the model.

```bash
.agents/tests/run.sh                    # everything
.agents/tests/run.sh harness_adapters   # one file by name
```

| Suite | Covers |
|---|---|
| `test_harness_adapters.sh` | Rules, skills, MCP servers and hooks rendered for each harness, the OpenCode plugin, and `init.sh` end to end |
| `test_hook_wiring.sh` | Hook settings point at scripts that exist and answer in a shape the CLI accepts |
| `test_mcp_registration.sh` | GitHub MCP registration and approval in Claude Code |
| `test_gh_account_scope.sh` | Which GitHub account a workspace's token comes from |
| `test_workspace_trust.sh` | The Claude Code workspace-trust grant and its revocation |
| `test_figma_setup.sh` | `setup-figma.sh` |
| `test_hooks_live.sh` | Live: the hooks inside a real `claude` session (calls the API) |

The live tests start the `claude` CLI in a sandbox project, drive it through a tool-calling loop, and read the hook events out of the `stream-json` transcript. They call the API, so the run needs `claude` on `PATH` and logged in, and it costs a few cents. See [tests/README.md](tests/README.md).