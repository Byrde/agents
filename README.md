# .agents

A library of self-contained, opinionated agent skills and rules for software development, adapted on install to Claude Code, Cursor, OpenAI Codex, GitHub Copilot and Google Antigravity. In Claude Code, the practice skills install as subagents (see [Practice subagents](#practice-subagents-claude-code)). OpenCode has its own installer, which turns the practice skills into agents (see [OpenCode](#opencode)). Drop it into any repository as a submodule. Two kinds of skills compose freely via shared verb+noun vocabulary ([`skills/CAPABILITIES.md`](skills/CAPABILITIES.md)): **practice skills** (the *what* — `plan`, `architect`, `design`, `develop`, `test`, `debug`, `review`, `quick-edit`, `docs`) ship with the repo. **Tool skills** (the *how* — `github-projects`, `jira`, `google-analytics`, `figma`, the vendored `figma-use`) are installed per-project by setup scripts. Some capabilities are always-on **rules** instead of opt-in skills — notably `workspace` (multi-repo routing) and `github-source-control` (branches/PRs/review) — installed automatically by `init.sh`.

## Usage

Use this repository as a submodule so another project keeps `.agents` at a pinned revision and can update it deliberately.

From the **root** of the host repository:

### Install

```bash
git submodule add https://github.com/Byrde/agents.git .agents
git commit -m "Add .agents submodule"
```

### Clone w/ Sub-Modules

```bash
git submodule update --init --recursive
```


### Update 

```bash
git submodule update --remote .agents
```

### Init parameters

| Parameter | Meaning |
|---|---|
| `--harness LIST` | Harnesses to install and adapt assets for, comma-separated. Names: `claude`, `cursor`, `codex`, `copilot`, `antigravity`, or `all`. Numbers select by position in `claude cursor codex copilot antigravity` (1–5). Also spelled `--harness=LIST` or `--harnesses LIST`. Skips the question. |
| `uninstall` (alias `remove`) | Removes rules, skills, hooks and settings from **every** harness, not only the selected ones. Tool skills from `setup-*.sh` stay; uninstall those with their own scripts. |
| `-h`, `--help`, `help` | Prints usage. |

| Environment variable | Meaning |
|---|---|
| `BYRDE_HARNESSES` | Same as `--harness`, for one run. The flag wins when both are set. The setup scripts read it too. |
| `BYRDE_WORKSPACE_MODE` | `mono` or `multi`: force the workspace flavor instead of auto-detecting it (see [Single-Repo or Multi-Repo Workspace](#single-repo-or-multi-repo-workspace)). |
| `BYRDE_RULES_REINJECT_EVERY` | Re-inject the rules every N tool calls (default `12`, `0` turns it off). Read at run time by the hooks, not by init. |

Which harnesses are used, in order of precedence: `--harness` > `BYRDE_HARNESSES` > the answer to the question (terminal only) > `harnesses` saved in `.workspace.agents.json` > `claude`.

The choice is saved as `harnesses` in `.workspace.agents.json`. Re-runs and every `setup-*.sh` script use it. Re-running with fewer harnesses removes what the dropped ones had. For example, `init.sh --harness claude` after `--harness all` removes the Cursor, Codex, Copilot and Antigravity files. A saved `opencode` entry from an older version is ignored.

### What init does

1. **Harnesses** — resolves the harnesses as described above
2. **Workspace map** — generates `.workspace.agents.json` at the project root, auto-detecting mono vs multi-repo (see [Single-Repo or Multi-Repo Workspace](#single-repo-or-multi-repo-workspace)). Gitignored
3. **Rules** — renders each `.agents/rules/*.md` into each harness's format (see [Harnesses](#harnesses))
4. **Skills** — makes `.agents/skills/` visible to each harness. For Claude Code, the practice skills become subagents in `.claude/agents/`, and an old `.claude/skills/` copy of each is removed
5. **GitHub — removes the GitHub MCP server that an older install registered. GitHub goes through the `gh` CLI (see [GitHub](#github))
6. **Auto-memory** (Claude Code only) — sets `autoMemoryEnabled: true` in `.claude/settings.json` (turning on Claude Code's built-in auto-memory, the default) and pins `autoMemoryDirectory` to the absolute path of `./memory` in `.claude/settings.local.json` (project-local storage, git-tracked and shared with the team).
7. **Hooks** — writes two hooks for each harness that has them: an allow-all pre-tool hook that approves every tool call, and a post-tool hook that re-injects the rules (see below)

### Single-Repo or Multi-Repo Workspace

`.agents` works whether you open your agent in a single repository or in a folder that sits above several repos. `init.sh` detects which and sets it up — no separate step, nothing to declare up front.

- **Single repo (`mono`).** `.agents` is a submodule at the repo root and you work from that root. Tool skills + the manifest stage in the checkout (`.agents/skills/`, `.agents/.manifest.local.yml`).

- **Multi-repo workspace (`multi`).** One `.agents` lives at a folder above several sibling repositories, and you open your agent at that folder to work across all of them. The always-on [workspace rule](#rules) reads a generated map (`.workspace.agents.json` at the context root) to learn what each repo is and routes every task to the right one. (If you instead `cd` into one repo to configure a tool skill scoped to it, that repo's rendered skills + manifest stage in its own `<repo>/.byrde/` so repos never clobber each other.)

`init.sh` auto-detects the flavor (multiple sibling repos ⇒ `multi`, else `mono`), writes `.workspace.agents.json`, and installs the workspace rule. Re-running `init.sh` refreshes the map (and preserves a `mode` you've hand-edited). To force the flavor, set `BYRDE_WORKSPACE_MODE=mono|multi` or edit `mode` in the map.

## What's included

### Rules

Always on. `init.sh` renders each one into every selected harness (see [Harnesses](#harnesses)).

| Rule | What it covers |
|---|---|
| [`global`](rules/global.md) | Project-wide baseline. Picks the weight of each unit of work (`solo`, `quick-edit` or the dedicated practices), then routes it. The lead rule: re-injected in full during long sessions (see [Rules re-injection](#rules-re-injection)) |
| [`step-back`](rules/step-back.md) | Stop patching and re-evaluate the design when the work goes in circles: the third attempt, a patch on a patch, a test bent to pass |
| [`development`](rules/development.md) | Architectural standards — Lite DDD modular monolith by default |
| [`github-source-control`](rules/github-source-control.md) | Branches, pull requests and code review through the `gh` CLI, as the workspace's GitHub account |
| [`workspace`](rules/workspace.md) | Finds which repository a task belongs to in a multi-repo workspace, and works inside it |
| [`memory`](rules/memory.md) | When to write memory, and what belongs in it (pairs with Claude Code's built-in auto-memory) |
| [`technical-writing`](rules/technical-writing.md) | ASD-STE100 Simplified Technical English for docs, work items and specs |

### Practice skills

Ship with the repo. `init.sh` makes them visible to every selected harness.

| Skill | Invoke it before you… |
|---|---|
| [`solo`](skills/solo/SKILL.md) | the `global` rule's weight check picks it: one pull request, one repository, no new boundary. Shapes, plans, builds test-first, verifies and ships in one pass. Keeps a `project.md` only when the work needs a record, and escalates to the dedicated practices when the work outgrows it |
| [`plan`](skills/plan/SKILL.md) | create, split or re-scope a work item |
| [`architect`](skills/architect/SKILL.md) | change a module boundary, add a dependency, or decide build-vs-buy |
| [`design`](skills/design/SKILL.md) | build or change a screen, flow or component |
| [`develop`](skills/develop/SKILL.md) | make the first edit of a change that will open a pull request (TDD, one slice at a time) |
| [`test`](skills/test/SKILL.md) | claim an implementation meets its acceptance criteria |
| [`debug`](skills/debug/SKILL.md) | fix anything reported as broken, even when the fix looks obvious (reproduce, prove, encode as a test) |
| [`review`](skills/review/SKILL.md) | review code, a diff, a branch or a pull request (findings ranked by severity) |
| [`quick-edit`](skills/quick-edit/SKILL.md) | make a small, fully specified edit that opens no pull request |
| [`docs`](skills/docs/SKILL.md) | write or substantially rewrite prose for people: a README, a guide, a changelog |

### Practice subagents (Claude Code)

In Claude Code, each skill with `category: practice` installs as `.claude/agents/<name>.md`, not as a skill. The file holds the skill's description, the shared preamble ([`scripts/lib/subagent-preamble.md`](scripts/lib/subagent-preamble.md)) and the skill's method. The method is the subagent's system prompt, so it does not fade as the main session grows.

A subagent cannot ask the user. When a step needs a decision, it stops and returns **Needs decision**. The main session asks you, then resumes the subagent with the answer. When a practice hands work to another one, such as `debug` to `develop`, the subagent returns **Handoff**, and the main session delegates. Subagents return **Memory candidates**, and the main session writes them. The `global` rule tells the main session to do all of this.

The other harnesses read the practice skills as skills, from `.agents/skills/`.

#### Models for the subagents

Each practice subagent runs on a fixed Claude model and effort. The table is `harness_agent_model` in [`scripts/lib/harness.sh`](scripts/lib/harness.sh), maintained by hand:

| Subagents | Model | Effort |
|---|---|---|
| `plan`, `architect`, `design`, `review` | `opus` | `high` |
| `develop`, `test`, `debug`, `docs` | `sonnet` | `high` |
| `quick-edit` | `haiku` | the session's |

The aliases follow the newest release of each family, so a new release needs no change. Edit the table to change a family or an effort, then re-run `init.sh`.

### Tool skills

Opt-in, one setup script each (see [Setup Tools](#setup-tools)). Each renders its skill from a template in [`tools/`](tools/) (`figma-use` is vendored from upstream instead) and registers the MCP server it needs, if any.

| Skill | Setup script | Owns | MCP server |
|---|---|---|---|
| `github-projects` | `setup-github-project.sh` | Work items, milestones, board state on a GitHub project board | GitHub (shared with source control) |
| `jira` | `setup-jira.sh` | Work items and the project board in Jira | Atlassian Remote MCP |
| `google-analytics` | `setup-google-analytics.sh` | GA4 reporting queries | Google `analytics-mcp` |
| `figma` + `figma-use` | `setup-figma.sh` | Design tokens, components and design work in one Figma file | Figma |

Pick one work-item tracker per project: `github-projects` and `jira` claim the same operations.

## Init

One-command bootstrap that installs rules, skills and hooks, adapted to each agent harness you choose:

```bash
cd /your/project
.agents/scripts/init.sh                          # Claude Code only (asks first on a terminal)
.agents/scripts/init.sh --harness claude,cursor  # these harnesses, no question
.agents/scripts/init.sh --harness all            # every harness
.agents/scripts/init.sh uninstall                # remove everything init installed
```

**The default is Claude Code and nothing else.** On a terminal, init shows the harness list with Claude Code ticked, and Enter accepts it. A non-interactive run (CI, a script, piped stdin) installs for Claude Code without asking. Once a choice is saved, it becomes the default for later runs.

## Harnesses

Every asset has one source, and each harness gets it in its own files and format. The adapters live in [`scripts/lib/harness.sh`](scripts/lib/harness.sh):

| | Rules | Skills | MCP servers | Hooks |
|---|---|---|---|---|
| **Claude Code** | `.claude/rules/*.md` | `.claude/agents/` (practice), `.claude/skills/` (others) | `.mcp.json` | `.claude/settings.json` |
| **Cursor** | `.cursor/rules/*.mdc` (`alwaysApply`) | `.agents/skills/` | `.cursor/mcp.json` | `.cursor/hooks.json` |
| **OpenAI Codex** | one fenced section per rule in `AGENTS.md` | `.agents/skills/` | `.codex/config.toml` | `.codex/hooks.json` |
| **GitHub Copilot** | `.github/instructions/*.instructions.md` (`applyTo: "**"`) | `.agents/skills/` | `.vscode/mcp.json` | `.github/hooks/byrde-agents.json` |
| **Google Antigravity** | `.agents/rules/*.md`, read in place | `.agents/skills/` | `.agents/mcp_config.json` | — |

**`.agents/` is shared ground.** Cursor, Codex, Copilot and Antigravity all read `.agents/skills/` natively, and Antigravity reads `.agents/rules/` too. That folder is this checkout, so they use the source in place and nothing is copied twice. Only Claude Code gets a copy. Rule sources carry `description` and `trigger: always_on` frontmatter for this reason. The other formats are rendered from them, so there is no hand-kept `.mdc` twin.

Things to know:

- **Codex** loads `.codex/` only in a trusted project, and asks you to trust each hook once (`/hooks`). Your own text in `AGENTS.md` is kept. Only the `<!-- byrde-agents:rule … -->` sections are rewritten. Cursor, Copilot and Antigravity read `AGENTS.md` as well, so selecting Codex with them loads the rules twice in those tools.
- **Tokens.** Antigravity cannot read the environment in its MCP config, so a tool's MCP server that needs a token is skipped for it, not written with a secret.
- **Antigravity hooks**: none. Its `PostToolUse` cannot add context.
- **Copilot**: `.vscode/mcp.json` is for VS Code. Copilot CLI reads `.mcp.json`, which exists when Claude Code is selected too. The coding agent takes MCP config from repository settings, not from a file.
- **Claude Code only**: auto-memory and `permissions.defaultMode`. They are removed when Claude Code is dropped. Claude Code reads them only in a trusted workspace (see [Workspace trust](#workspace-trust-claude-code)).

## Rules re-injection

Rules load once, at session start. Nothing re-asserts them, so they lose to the most recent tool result as a session grows, and compliance decays without anyone noticing.

[`scripts/hooks/reinject-rules.sh`](scripts/hooks/reinject-rules.sh) runs after each tool call (**`PostToolUse`**) and re-injects the rules every 12 tool calls. `--harness` selects the answer shape: Claude Code and Codex read `hookSpecificOutput.additionalContext`, Cursor reads `additional_context`, and Copilot reads `additionalContext`. The trigger is a tool call rather than a user message on purpose: the model works through many tool calls between two of your messages, and that output is what buries the rules. The stream that buries them brings them back.

It injects the **short form** — `global.md` in full, plus the names of the other rule files. Repeating every rule file on a tool-call cadence would eat the context the rules are meant to protect.

Set the cadence with `BYRDE_RULES_REINJECT_EVERY` (default `12`, `0` disables).

One trap worth knowing if you write your own hook: `PostToolUse` **ignores stdout**. The model only reads `hookSpecificOutput.additionalContext`, so the hook answers with JSON. `UserPromptSubmit` is the opposite — there, stdout *is* the injection. Both shapes are handled, so an install wired the old way keeps working until you re-run `init.sh`.

## Workspace trust (Claude Code)

Claude Code ignores a project's `.claude/settings.json` until the workspace is trusted. The hooks and the permission mode that init writes there load only after you accept Claude Code's trust dialog. `init.sh` grants no trust.

An older `init.sh` set `projects["<root>"].hasTrustDialogAccepted` in `~/.claude.json` and recorded the grant as `workspace-trust` in `.manifest.local.yml`. `init.sh uninstall` gives back only that recorded grant. If you accepted the trust dialog yourself, an uninstall leaves your decision alone. Uninstall never creates `~/.claude.json`, and never rewrites it when it cannot be parsed.

## Optional setup

Run these separately when you want them (see [Setup Tools](#setup-tools)):

- `.agents/scripts/setup/setup-github-project.sh` — pin a GitHub project board (source control is set up by `init.sh`)
- `.agents/scripts/setup/setup-jira.sh` — pin a Jira site + project
- `.agents/scripts/setup/setup-google-analytics.sh` — pin a GA4 property
- `.agents/scripts/setup/setup-figma.sh` — the Figma tool skill

**Uninstall.** Every setup script takes an `uninstall` subcommand that reverses exactly what its install wrote:

```bash
.agents/scripts/init.sh uninstall            # remove rules, skills and hooks from every harness, the workspace map, the auto-memory flag
.agents/scripts/setup/setup-github-project.sh uninstall  # remove the github-projects skill
.agents/scripts/setup/setup-jira.sh uninstall    # remove the jira skill + Atlassian MCP server
.agents/scripts/setup/setup-google-analytics.sh uninstall  # remove the google-analytics skill + MCP server
.agents/scripts/setup/setup-figma.sh uninstall    # remove Figma skills (incl. figma-use) + MCP server
```

## OpenCode

OpenCode 2 has its own installer in [`scripts/opencode/`](scripts/opencode/). It does not use `init.sh` or the harness adapters. The practice skills become **agents**, and each agent runs on the model that suits its kind of work.

```bash
cd /your/project
.agents/scripts/opencode/setup-fuelix.sh              # optional: add Fuel iX models as a provider
.agents/scripts/opencode/init.sh                      # install, then score the models
.agents/scripts/opencode/init.sh evaluate             # re-score after a provider change
.agents/scripts/opencode/init.sh uninstall            # remove what init wrote
```

**Requires:** OpenCode 2, `jq`, `python3`, `curl`, `git`. For scoring, an [Artificial Analysis](https://artificialanalysis.ai/) API key (free tier) in `ARTIFICIAL_ANALYSIS_API_KEY`.

## What the OpenCode init writes

| File | Content |
|---|---|
| `.opencode/agents/<skill>.md` | One agent per practice skill, `mode: all`: switch to it with Tab, or let the main agent delegate to it. `model:` is the scored pick. With no pick, the agent inherits the session's model. |
| `.opencode/opencode.json` | Merged, never replaced. `permissions` allows every tool call and denies each practice skill as a *skill*, because it is an agent now. An old GitHub MCP server is removed. |
| `.opencode/plugins/byrde-agents.js` | The plugin. See [The plugin](#the-plugin). |
| `.opencode/byrde-agents.json` | The plugin's settings, and the last evaluation. |
| `AGENTS.md` | One fenced section per rule in `.agents/rules/`. Your text outside the fences stays. |
| `memory/` | Project memory: git-tracked and shared with the team. |
| `.workspace.agents.json` | The workspace map, shared with `init.sh`. |
| `.gitignore` | A `byrde-agents opencode` block for the generated files. |

The agent files have no body. In OpenCode, a body replaces the default system prompt, and the agent then loses OpenCode's guidance on how to use its tools. The plugin adds the skill's method to the prompt instead.

GitHub goes through the `gh` CLI, as in the other harnesses (see [GitHub](#github)).

## Model scoring

Every run of `init.sh` and `init.sh evaluate` scores the models again:

1. It lists the models that OpenCode can use in this project (`opencode api GET /api/model`).
2. It matches each model to an Artificial Analysis benchmark entry. A model with no match is reported and not scored.
3. It scores the quality of each model against the profile of each practice skill.
4. It pins the cheapest model whose quality is within the profile's margin of the best one.

**Data.** The free endpoint, `/api/v2/language/models/free`, replaced the old one on 2026-11-04. It carries the intelligence index alone. The coding and agentic indexes need a Pro key: set `BYRDE_AA_URL` to `https://artificialanalysis.ai/api/v2/language/models`. A dimension that no model has data for is left out of each profile, so free data scores on intelligence.

**Quality.** Each benchmark score is divided by the best score that Artificial Analysis lists, so 0.95 means 95% of the best. The benchmarks roll up into dimensions:

| Dimension | Benchmarks |
|---|---|
| intelligence | Artificial Analysis intelligence index |
| coding | coding index, SciCode, LiveCodeBench |
| agentic | agentic index, Terminal-Bench, τ²-bench, τ²-bench banking |
| reasoning | Humanity's Last Exam, GPQA, AIME |
| long-context | AA-LCR |

A dimension uses the benchmarks that a model has. A dimension with no data counts as 0.5, so a gap in the benchmarks never helps a model. Artificial Analysis publishes no instruction-following or hallucination data for current models, so neither is a dimension.

**Profiles.** Each practice skill maps to one profile:

| Profile | Skills | Quality weights | Margin |
|---|---|---|---|
| `deep` | plan, architect, design, review | reasoning 0.35, intelligence 0.35, long-context 0.2, agentic 0.1 | 5% |
| `build` | develop, test, debug | coding 0.4, agentic 0.4, intelligence 0.2 | 5% |
| `write` | docs | intelligence 0.6, long-context 0.4 | 5% |
| `fast` | quick-edit | coding 0.5, intelligence 0.5 | 50% |

5% is about the noise between two benchmark runs. A quick edit needs a model that is good enough, not one near the best, so `fast` accepts half the best quality.

**Cost.** Cost is the estimated price of one answer: 10,000 input tokens, 1,000 output tokens, and the thinking tokens. The thinking tokens are the time to the first answer token multiplied by the output speed. So a higher reasoning effort costs more, even at the same price per token. For example, Opus 5.5 at max effort thinks for about 390 seconds and costs about $0.82 per answer. At xhigh effort it thinks for about 50 seconds and costs about $0.14. The prices are the deployment's own when OpenCode lists them, so a free model costs nothing. Otherwise they are the Artificial Analysis list prices.

The report shows the top three candidates for each agent, with their quality and their cost per answer.

The agents **inherit** the session's model in these cases:

- The only provider is OpenCode's built-in one. Its free models count only when you configure another provider.
- `ARTIFICIAL_ANALYSIS_API_KEY` is not set and no earlier download is cached. With a cache, init reuses it and says so.
- No model meets the coverage floor for that skill.

Benchmark data: [Artificial Analysis](https://artificialanalysis.ai/). Their free API requires attribution, so the report credits it.

## The plugin

The plugin uses two OpenCode 2 hooks:

| Hook | What it does |
|---|---|
| `session.hook("context")` | For a practice agent, adds that skill's `SKILL.md` to the system prompt. For every agent, adds where memory lives and the `memory/MEMORY.md` index. |
| `tool.hook("execute.after")` | Every `BYRDE_RULES_REINJECT_EVERY` tool calls (default 12, `0` turns it off), appends the lead rule to the tool result. |

Allow-all is a `permissions` rule in `opencode.json`, not a hook.

## Fuel iX

`setup-fuelix.sh` lists the models that Fuel iX serves and asks which ones to add. `--models a,b,c` skips the question. Each family goes to the provider for its API:

| Provider | Models | Package |
|---|---|---|
| `fuelix-anthropic` | `claude-*` | `@ai-sdk/anthropic` |
| `fuelix-openai` | `gpt-*`, `o<digit>*` | `@ai-sdk/openai` (Responses API) |
| `fuelix` | all others | `@ai-sdk/openai-compatible` (Chat Completions) |

The three providers belong to the script. A re-run replaces their models with the new choice, then re-runs the evaluation. The key stays in `FUELIX_API_KEY`: the config names it, and OpenCode reads it at run time.

## Setup Tools

### GitHub

GitHub has two parts, and both use the `gh` CLI. No MCP server is involved.

**Source control** (branches, pull requests, review, merge) needs no setup. `init.sh` installs the always-on `github-source-control` **rule**. The rule tells the agent to run `gh`, and to resolve the target repo for each task from `.workspace.agents.json`. `gh` runs as the account that is active on the machine. Log in once with `gh auth login`, and run `gh auth switch` to change the account. For a SAML-SSO organization, authorize your `gh` login for the organization.

An older install registered a GitHub MCP server. `init.sh` and the OpenCode init remove it on the next run. They remove only a server named `github` that points at `https://api.githubcopilot.com/mcp/`, and its approval in `.claude/settings.json`.

**Projects** (work items, milestones, board state) is the one piece that needs a pin — a project board (owner + board number) can't be auto-detected — so it stays an explicit, opt-in step:

**Requires:** `gh` (GitHub CLI, authenticated, `read:project` scope), `jq`, `python3`

```bash
cd /your/workspace
.agents/scripts/setup/setup-github-project.sh            # pin a board + install the github-projects skill
.agents/scripts/setup/setup-github-project.sh uninstall  # remove the github-projects skill
```

It walks you through your account, owner, the repo the board mainly tracks, and the board ID. It then writes `skills/github-projects/SKILL.md`, made visible to each selected harness. The skill runs every issue, milestone and board operation through the same `gh` wrapper.

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

## Doctor

Diagnoses the health of what `init.sh` and the setup scripts configured.

```bash
cd /your/project
.agents/scripts/doctor.sh
```

Reports, for each selected harness, whether its rules, skills and hooks are installed, and checks the workspace map. Then, for each tool that is set up (recorded in `.manifest.local.yml`), it reports the skill, the MCP configuration per harness, authentication, and server reachability. For GitHub (source control and projects), it checks the `gh` login as the workspace's account, and warns about an old GitHub MCP server. The other tools are Figma (`figma`, `figma-use`), Google Analytics and Jira. A tool you never installed, or uninstalled, is left out of the report.

## Tests

Offline suites cover the installer itself, and live tests verify that the hooks work inside a real Claude Code session — that the session runs them mid-loop, and that what they emit reaches the model.

```bash
.agents/tests/run.sh                    # everything
.agents/tests/run.sh harness_adapters   # one file by name
```

| Suite | Covers |
|---|---|
| `test_harness_adapters.sh` | Rules, skills, MCP servers and hooks rendered for each harness, and `init.sh` end to end |
| `test_hook_wiring.sh` | Hook settings point at scripts that exist and answer in a shape the CLI accepts |
| `test_github_cli.sh` | GitHub through `gh`: no MCP server, and the old one is removed |
| `test_workspace_trust.sh` | init grants no workspace trust, and uninstall revokes an old grant |
| `test_figma_setup.sh` | `setup-figma.sh` |
| `test_opencode.sh` | The OpenCode installer, the model scoring, `setup-fuelix.sh` and the plugin |
| `test_hooks_live.sh` | Live: the hooks inside a real `claude` session (calls the API) |

The live tests start the `claude` CLI in a sandbox project, drive it through a tool-calling loop, and read the hook events out of the `stream-json` transcript. They call the API, so the run needs `claude` on `PATH` and logged in, and it costs a few cents. See [tests/README.md](tests/README.md).