#!/usr/bin/env bash
# Bootstrap a host project with Byrde Agents.
#
# Asks which agent harnesses to install for — Claude Code, Cursor, OpenAI Codex,
# GitHub Copilot, Google Antigravity — and adapts every asset (rules, skills,
# the GitHub MCP server, hooks) to each one's own files and formats (see
# lib/harness.sh for where each lands). Turns ON Claude Code's
# built-in auto-memory (the default). Optional setup steps (the GitHub
# projects, Jira, Google Analytics and Figma tool skills) are run separately
# as their own scripts.
#
# Run from the repository/project root you want to initialise.
# Writes, for each selected harness (the table in lib/harness.sh is canonical):
#   - rules   .claude/rules/*.md · .cursor/rules/*.mdc · AGENTS.md sections (Codex)
#             · .github/instructions/*.instructions.md (Copilot)
#             · .agents/rules/ is read in place by Antigravity
#   - skills  .claude/skills/ · .agents/skills/ is read in place by the others
#   - hooks   .claude/settings.json · .cursor/hooks.json · .codex/hooks.json
#             · .github/hooks/byrde-agents.json
#   - .workspace.agents.json  — workspace repo map (auto-detected mono/multi);
#                               the always-on workspace rule routes against it
#   - .cursor/rules/workspace.mdc, .claude/rules/workspace.md — the routing rule
#                               (shipped in .agents/rules/, installed by copy_rules)
#   - .claude/settings.json       — autoMemoryEnabled: true (Claude Code default)
#                                   + permissions.defaultMode: auto
#                                   (auto-approve tool calls with safety checks)
#                                   + permissions.allow: ["Edit", "Write"]
#                                   (Edit/Write always allowed, even outside auto mode)
#   - .claude/settings.local.json — autoMemoryDirectory: <abs>/memory
#                                   (machine-specific; Claude Code ignores
#                                   relative paths, so we resolve it at init time)
#   - .gitignore                  — one "byrde-agents" fenced block ignoring the
#                                   generated, regenerable artefacts: .claude/,
#                                   .cursor/, .mcp.json, .worktrees/, and
#                                   .workspace.agents.json. The memory CONTENT
#                                   lives at the project root (not under .claude/),
#                                   so nothing in the block ignores it and it
#                                   stays git-tracked and shared
#
# Does not modify $HOME.
#
# Usage:
#   cd /path/to/project && /path/to/init.sh                          # install (asks; default: opencode)
#   cd /path/to/project && /path/to/init.sh --harness claude,codex   # install, no question
#   cd /path/to/project && /path/to/init.sh uninstall                # remove what install wrote
#
# The choice is saved as `harnesses` in .workspace.agents.json; the setup-*.sh
# scripts install for the same set. BYRDE_HARNESSES overrides it for one run.
#
# Requires: jq (only for the auto-memory step; rules/skills work without it)
# Compatible with Bash 3.2 (macOS): no mapfile/readarray.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENTS_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# init seeds the SHARED, submodule-tracked practice skills + rules, so it always
# reads from the .agents checkout (not a per-repo staging home). It sources
# layout.sh for is_tool_skill (the rendered/vendored tool skills are owned by the
# setup-*.sh scripts and must NOT be seeded here) and workspace.sh to generate
# the workspace repo map that the always-on workspace rule routes against.
# shellcheck source=lib/layout.sh
. "$SCRIPT_DIR/lib/layout.sh"
# shellcheck source=lib/workspace.sh
. "$SCRIPT_DIR/lib/workspace.sh"
# shellcheck source=lib/mcp.sh
. "$SCRIPT_DIR/lib/mcp.sh"
# manifest.sh migrates the old github-source-control skill.
# shellcheck source=lib/manifest.sh
. "$SCRIPT_DIR/lib/manifest.sh"
# shellcheck source=lib/trust.sh
. "$SCRIPT_DIR/lib/trust.sh"
# shellcheck source=lib/harness.sh
. "$SCRIPT_DIR/lib/harness.sh"
SKILLS_DIR="$AGENTS_ROOT/skills"
RULES_DIR="$AGENTS_ROOT/rules"

TOOL_VERSION="0.1.0"
PROG_NAME="$(basename "${BASH_SOURCE[0]}")"

# Project-local directory for Claude Code's built-in auto-memory, relative to the
# project root. The memory CONTENT lives here and is git-tracked (the single
# byrde-agents .gitignore block never ignores it) so it is shared across the
# team; the absolute path is
# written per-machine into settings.local.json (see set_auto_memory_dir_local).
AUTO_MEMORY_DIR="memory"

# ─── Utilities ───────────────────────────────────────────────────────────────

die() {
  echo "error: $*" >&2
  exit 1
}

# Configure Claude Code's built-in auto-memory in .claude/settings.json:
# the autoMemoryEnabled flag and (optionally) the autoMemoryDirectory path.
# Auto-memory is ON by default; init turns it on explicitly — and pins the
# directory into this project's .claude/ — so the project state is
# unambiguous.
# Best-effort: needs jq to merge safely. Warns and skips if jq is missing —
# the auto-memory default still applies, it just isn't written explicitly.
set_auto_memory() {
  local project_root="$1" value="$2" dir="${3:-}"  # value: true | false; dir: optional path
  local settings="$project_root/.claude/settings.json"
  if ! command -v jq >/dev/null 2>&1; then
    echo "  ⚠ jq not found — skipping autoMemoryEnabled=$value${dir:+ / autoMemoryDirectory=$dir}"
    echo "    (set these in $settings manually if needed)"
    return 0
  fi
  mkdir -p "$(dirname "$settings")"
  local tmp filter
  tmp="$(mktemp)"
  # Always set the flag. Set the directory when supplied; otherwise strip any
  # stale autoMemoryDirectory (we now pin the absolute path in settings.local.json
  # instead — a relative path here is silently ignored by Claude Code).
  filter='.autoMemoryEnabled = $v'
  if [[ -n "$dir" ]]; then
    filter="$filter | .autoMemoryDirectory = \$d"
  else
    filter="$filter | del(.autoMemoryDirectory)"
  fi
  if [[ -f "$settings" ]]; then
    jq --argjson v "$value" --arg d "$dir" "$filter" "$settings" >"$tmp" \
      || { echo "  ⚠ jq failed on $settings — leaving auto-memory settings unchanged"; rm -f "$tmp"; return 0; }
  elif [[ -n "$dir" ]]; then
    jq -n --argjson v "$value" --arg d "$dir" '{autoMemoryEnabled: $v, autoMemoryDirectory: $d}' >"$tmp"
  else
    jq -n --argjson v "$value" '{autoMemoryEnabled: $v}' >"$tmp"
  fi
  mv "$tmp" "$settings"
  echo "  ✓ autoMemoryEnabled=$value${dir:+, autoMemoryDirectory=$dir} → .claude/settings.json"
}

# Remove the auto-memory keys from .claude/settings.json (uninstall), reverting
# Claude Code to its built-in defaults. Leaves any other settings intact, and
# removes the file only if it becomes an empty object.
del_auto_memory() {
  local project_root="$1"
  local settings="$project_root/.claude/settings.json"
  [[ -f "$settings" ]] || return 0
  command -v jq >/dev/null 2>&1 || { echo "  ⚠ jq not found — leaving $settings as-is"; return 0; }
  local tmp
  tmp="$(mktemp)"
  if jq 'del(.autoMemoryEnabled) | del(.autoMemoryDirectory)' "$settings" >"$tmp" 2>/dev/null; then
    if [[ "$(jq -S 'keys' "$tmp")" == "[]" ]]; then
      rm -f "$tmp" "$settings"
      echo "  ✓ removed auto-memory settings (and empty .claude/settings.json)"
    else
      mv "$tmp" "$settings"
      echo "  ✓ removed autoMemoryEnabled + autoMemoryDirectory from .claude/settings.json"
    fi
  else
    rm -f "$tmp"
    echo "  ⚠ jq failed on $settings — leaving it unchanged"
  fi
}

# Pin Claude Code's auto-memory DIRECTORY to an absolute, project-local path in
# .claude/settings.local.json. The path MUST be absolute (or ~/-prefixed) —
# Claude Code silently ignores relative paths and falls back to its global
# default (the bug this replaces). We resolve it at init time and write it to the
# LOCAL (always-gitignored, machine-specific) settings file rather than the
# regenerated settings.json: the absolute path differs per machine/clone, while
# the memory CONTENT under memory/ is committed and shared (the single
# byrde-agents .gitignore block never ignores it). Local scope also wins over
# project scope in Claude
# Code's settings precedence. Best-effort: needs jq.
set_auto_memory_dir_local() {
  local project_root="$1" abs_dir="$2"
  local settings="$project_root/.claude/settings.local.json"
  if ! command -v jq >/dev/null 2>&1; then
    echo "  ⚠ jq not found — skipping autoMemoryDirectory=$abs_dir (set it in $settings manually)"
    return 0
  fi
  mkdir -p "$(dirname "$settings")"
  local tmp
  tmp="$(mktemp)"
  if [[ -f "$settings" ]]; then
    jq --arg d "$abs_dir" '.autoMemoryDirectory = $d' "$settings" >"$tmp" \
      || { echo "  ⚠ jq failed on $settings — leaving it unchanged"; rm -f "$tmp"; return 0; }
  else
    jq -n --arg d "$abs_dir" '{autoMemoryDirectory: $d}' >"$tmp"
  fi
  mv "$tmp" "$settings"
  echo "  ✓ autoMemoryDirectory=$abs_dir → .claude/settings.local.json"
}

# Auto-approve tool calls in .claude/settings.json by setting the permission
# mode to auto — Claude Code then runs tools (Bash, edits, MCP servers, …) with
# background safety checks instead of prompting. One mode flag covers current and
# future tools, so no allowlist of tool names to keep in sync. Also explicitly
# allows Edit and Write (merged into any existing permissions.allow entries) so
# file edits stay unprompted even if defaultMode is later changed away from auto.
# Best-effort: needs jq.
set_allow_all_tools() {
  local project_root="$1"
  local settings="$project_root/.claude/settings.json"
  if ! command -v jq >/dev/null 2>&1; then
    echo "  ⚠ jq not found — skipping permissions.defaultMode=auto / permissions.allow"
    echo "    (set these in $settings manually if needed)"
    return 0
  fi
  mkdir -p "$(dirname "$settings")"
  local tmp filter
  tmp="$(mktemp)"
  filter='
    .permissions = (.permissions // {})
    | .permissions.defaultMode = "auto"
    | .permissions.allow = ((.permissions.allow // []) + ["Edit", "Write"] | unique)
  '
  if [[ -f "$settings" ]]; then
    jq "$filter" "$settings" >"$tmp" \
      || { echo "  ⚠ jq failed on $settings — leaving permissions unchanged"; rm -f "$tmp"; return 0; }
  else
    jq -n '{permissions: {defaultMode: "auto", allow: ["Edit", "Write"]}}' >"$tmp"
  fi
  mv "$tmp" "$settings"
  echo "  ✓ permissions.defaultMode=auto, allow=[Edit,Write] → .claude/settings.json (auto-approves tool calls with safety checks)"
}

# Remove the permission mode + allow entries init wrote (uninstall), reverting
# Claude Code to its default prompting behaviour. Only strips the "Edit"/"Write"
# entries init added — any other permissions.allow entries (e.g. Skill(...))
# are left intact. Removes permissions.allow if it becomes empty, and removes
# the file only if it becomes an empty object.
del_allow_all_tools() {
  local project_root="$1"
  local settings="$project_root/.claude/settings.json"
  [[ -f "$settings" ]] || return 0
  command -v jq >/dev/null 2>&1 || { echo "  ⚠ jq not found — leaving $settings as-is"; return 0; }
  local tmp filter
  tmp="$(mktemp)"
  filter='
    del(.permissions.defaultMode)
    | .permissions.allow = ((.permissions.allow // []) - ["Edit", "Write"])
    | (if (.permissions.allow // []) == [] then del(.permissions.allow) else . end)
    | if (.permissions // {}) == {} then del(.permissions) else . end
  '
  if jq "$filter" "$settings" >"$tmp" 2>/dev/null; then
    if [[ "$(jq -S 'keys' "$tmp")" == "[]" ]]; then
      rm -f "$tmp" "$settings"
      echo "  ✓ removed permissions settings (and empty .claude/settings.json)"
    else
      mv "$tmp" "$settings"
      echo "  ✓ removed permissions.defaultMode and allow=[Edit,Write] from .claude/settings.json"
    fi
  else
    rm -f "$tmp"
    echo "  ⚠ jq failed on $settings — leaving it unchanged"
  fi
}

# Marker command for the allow-all PreToolUse hook. Identity is keyed on this
# exact string so set/del/doctor agree and re-running init replaces rather than
# duplicates the hook.
ALLOW_ALL_HOOK_CMD='echo '\''{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","permissionDecisionReason":"byrde-agents allow-all auto-approve"}}'\'''

# Install an allow-all PreToolUse hook in .claude/settings.json: a command hook
# (matcher "*") that returns permissionDecision "allow" for every tool call. This
# goes beyond permissions.defaultMode=auto — it bypasses the auto-mode classifier,
# so even the destructive/irreversible actions auto mode would still gate are
# approved with no prompt. Idempotent (keyed on ALLOW_ALL_HOOK_CMD). Best-effort:
# needs jq. NOTE: AskUserQuestion is not permission-gated, so multi-select
# questions still reach the operator.
set_allow_all_hook() {
  local project_root="$1"
  local settings="$project_root/.claude/settings.json"
  if ! command -v jq >/dev/null 2>&1; then
    echo "  ⚠ jq not found — skipping allow-all PreToolUse hook"
    echo "    (add it to $settings manually if needed)"
    return 0
  fi
  mkdir -p "$(dirname "$settings")"
  local filter='
    .hooks = (.hooks // {})
    | .hooks.PreToolUse =
        (((.hooks.PreToolUse // [])
          | map(select(([.hooks[]?.command] | index($cmd)) | not)))
         + [{matcher: "*", hooks: [{type: "command", command: $cmd}]}])
  '
  local tmp
  tmp="$(mktemp)"
  if [[ ! -f "$settings" ]]; then echo '{}' >"$settings"; fi
  if jq --arg cmd "$ALLOW_ALL_HOOK_CMD" "$filter" "$settings" >"$tmp"; then
    mv "$tmp" "$settings"
    echo "  ✓ allow-all PreToolUse hook → .claude/settings.json (approves every tool call, no prompts)"
  else
    echo "  ⚠ jq failed on $settings — leaving hooks unchanged"; rm -f "$tmp"
  fi
}

# Command for the rules-reinjection UserPromptSubmit hook. Identity is keyed on the
# script path so re-running init replaces rather than duplicates it.
REINJECT_HOOK_CMD='"$CLAUDE_PROJECT_DIR"/.agents/scripts/hooks/reinject-rules.sh'

# Install a PostToolUse hook that re-injects the rules every Nth tool call.
#
# Rules load once, at session start. Nothing re-asserts them, so they lose to the
# most recent tool result as a session grows and compliance decays silently.
#
# The trigger is a tool call, not a user message. The model works for many tool
# calls between two of your messages, and that output is what buries the rules.
# Older installs wired this to UserPromptSubmit; this replaces that entry, so
# re-running init migrates them and nothing injects twice.
#
# Cadence: BYRDE_RULES_REINJECT_EVERY (default 12 tool calls, 0 disables).
set_rules_reinject_hook() {
  local project_root="$1"
  local settings="$project_root/.claude/settings.json"
  if ! command -v jq >/dev/null 2>&1; then
    echo "  ⚠ jq not found — skipping rules-reinjection hook"
    return 0
  fi
  mkdir -p "$(dirname "$settings")"
  local filter='
    .hooks = (.hooks // {})
    | .hooks.PostToolUse =
        (((.hooks.PostToolUse // [])
          | map(select(([.hooks[]?.command] | index($cmd)) | not)))
         + [{matcher: "*", hooks: [{type: "command", command: $cmd}]}])
    | (if (.hooks.UserPromptSubmit | type) == "array" then
         .hooks.UserPromptSubmit =
           (.hooks.UserPromptSubmit | map(select(([.hooks[]?.command] | index($cmd)) | not)))
         | (if (.hooks.UserPromptSubmit | length) == 0 then del(.hooks.UserPromptSubmit) else . end)
       else . end)
  '
  local tmp
  tmp="$(mktemp)"
  if [[ ! -f "$settings" ]]; then echo '{}' >"$settings"; fi
  if jq --arg cmd "$REINJECT_HOOK_CMD" "$filter" "$settings" >"$tmp"; then
    mv "$tmp" "$settings"
    echo "  ✓ rules re-injected every ${BYRDE_RULES_REINJECT_EVERY:-12} tool calls → .claude/settings.json"
  else
    echo "  ⚠ jq failed on $settings — leaving hooks unchanged"; rm -f "$tmp"
  fi
}

# Remove the rules-reinjection hook (uninstall). Clears both the current
# PostToolUse entry and the UserPromptSubmit entry older installs wrote. Leaves
# other hooks intact.
del_rules_reinject_hook() {
  local project_root="$1"
  local settings="$project_root/.claude/settings.json"
  [[ -f "$settings" ]] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  local tmp
  tmp="$(mktemp)"
  local filter='
    reduce ("PostToolUse", "UserPromptSubmit") as $ev (.;
      if (.hooks[$ev] | type) == "array" then
        .hooks[$ev] = (.hooks[$ev] | map(select(([.hooks[]?.command] | index($cmd)) | not)))
        | (if (.hooks[$ev] | length) == 0 then del(.hooks[$ev]) else . end)
      else . end)
    | (if (.hooks // {}) == {} then del(.hooks) else . end)
  '
  if jq --arg cmd "$REINJECT_HOOK_CMD" "$filter" "$settings" >"$tmp"; then
    mv "$tmp" "$settings"
  else
    rm -f "$tmp"
  fi
}

# Remove the allow-all PreToolUse hook init wrote (uninstall), pruning an emptied
# PreToolUse array and .hooks object, and deleting the file if it becomes empty.
# Leaves any other hooks intact. Mirrors del_allow_all_tools.
del_allow_all_hook() {
  local project_root="$1"
  local settings="$project_root/.claude/settings.json"
  [[ -f "$settings" ]] || return 0
  command -v jq >/dev/null 2>&1 || { echo "  ⚠ jq not found — leaving $settings as-is"; return 0; }
  local filter='
    if (.hooks.PreToolUse | type) == "array" then
      .hooks.PreToolUse = (.hooks.PreToolUse
        | map(select(([.hooks[]?.command] | index($cmd)) | not)))
      | (if (.hooks.PreToolUse | length) == 0 then del(.hooks.PreToolUse) else . end)
      | (if (.hooks // {}) == {} then del(.hooks) else . end)
    else . end
  '
  local tmp
  tmp="$(mktemp)"
  if jq --arg cmd "$ALLOW_ALL_HOOK_CMD" "$filter" "$settings" >"$tmp" 2>/dev/null; then
    if [[ "$(jq -S 'keys' "$tmp")" == "[]" ]]; then
      rm -f "$tmp" "$settings"
      echo "  ✓ removed allow-all hook (and empty .claude/settings.json)"
    else
      mv "$tmp" "$settings"
      echo "  ✓ removed allow-all PreToolUse hook from .claude/settings.json"
    fi
  else
    rm -f "$tmp"
    echo "  ⚠ jq failed on $settings — leaving it unchanged"
  fi
}

# Remove the autoMemoryDirectory key from .claude/settings.local.json (uninstall),
# deleting the file if it becomes an empty object. Mirrors del_auto_memory.
del_auto_memory_dir_local() {
  local project_root="$1"
  local settings="$project_root/.claude/settings.local.json"
  [[ -f "$settings" ]] || return 0
  command -v jq >/dev/null 2>&1 || { echo "  ⚠ jq not found — leaving $settings as-is"; return 0; }
  local tmp
  tmp="$(mktemp)"
  if jq 'del(.autoMemoryDirectory)' "$settings" >"$tmp" 2>/dev/null; then
    if [[ "$(jq -S 'keys' "$tmp")" == "[]" ]]; then
      rm -f "$tmp" "$settings"
      echo "  ✓ removed autoMemoryDirectory (and empty .claude/settings.local.json)"
    else
      mv "$tmp" "$settings"
      echo "  ✓ removed autoMemoryDirectory from .claude/settings.local.json"
    fi
  else
    rm -f "$tmp"
    echo "  ⚠ jq failed on $settings — leaving it unchanged"
  fi
}

# Memory re-include is folded into the single byrde-agents .gitignore block
# (see manage_editor_gitignore). The shared memory/ dir sits at the project root,
# so nothing in that block ignores it and its contents stay git-tracked across
# the team; legacy standalone "shared memory" blocks are swept up by
# _strip_byrde_gitignore.

# Marker for the single managed `.gitignore` block that lists every generated
# byrde-agents artefact (editor dirs, project MCP config, the workspace map) plus
# the per-branch worktree dir.
BYRDE_GI_START="# --- byrde-agents ---"
BYRDE_GI_END="# --- end byrde-agents ---"

# Strip the managed block plus any legacy variants, so re-running is idempotent
# and older layouts (the old "(managed by init.sh)" marker, a separate "editor
# dirs" block, the standalone shared-memory block, or a standalone workspace-map
# entry) get folded into the single block. Leaves a hand-rolled ignore alone.
_strip_byrde_gitignore() {
  local gi="$1"
  [[ -f "$gi" ]] || return 0
  sed -i '' "/$BYRDE_GI_START/,/$BYRDE_GI_END/d" "$gi" 2>/dev/null || true
  # Legacy: the old start marker that carried the "(managed by init.sh)" suffix.
  sed -i '' "/# --- byrde-agents (managed by init.sh) ---/,/# --- end byrde-agents ---/d" "$gi" 2>/dev/null || true
  # Legacy: the old "editor dirs" fenced block.
  sed -i '' "/# --- byrde-agents editor dirs (managed by init.sh) ---/,/# --- end byrde-agents editor dirs ---/d" "$gi" 2>/dev/null || true
  # Legacy: the old standalone shared-memory fenced block.
  sed -i '' "/# --- byrde-agents shared memory (managed by init.sh) ---/,/# --- end byrde-agents shared memory ---/d" "$gi" 2>/dev/null || true
  # Legacy: the old standalone workspace-map comment + anchored entry.
  sed -i '' "/# Byrde Agents.*workspace repo map/d" "$gi" 2>/dev/null || true
  sed -i '' "\#^/\.workspace\.agents\.json\$#d" "$gi" 2>/dev/null || true
  # Trim trailing blank lines left behind.
  sed -i '' -e :a -e '/^[[:space:]]*$/{' -e '$d' -e N -e ba -e '}' "$gi" 2>/dev/null || true
}

# Ignore every generated byrde-agents artefact in the project's .gitignore as one
# fenced block: what each selected harness's adapters write (see
# harness_gitignore_entries), the workspace map (.workspace.agents.json), and the
# per-branch worktree dir (.worktrees/). init.sh and the setup-*.sh scripts produce these
# from the .agents submodule, so they're regenerable — not worth committing. The
# block re-includes .claude/memory/ ahead of the blanket ignores; the shared
# memory/ dir sits at the project root — NOT under .claude/ — so it's never
# blocked either way. Upserts the file and rewrites the block, so it's idempotent.
manage_editor_gitignore() {
  local project_root="$1"
  local gi="$project_root/.gitignore"
  local map h lines=""
  map="$(basename "$WORKSPACE_FILE")"   # .workspace.agents.json
  for h in $(harness_selected); do
    lines="$lines$(harness_gitignore_entries "$project_root" "$h" "$RULES_DIR")"$'\n'
  done
  lines="$lines.worktrees/"$'\n'"$map"
  # Codex and OpenCode can both name AGENTS.md; list each path once.
  lines="$(printf '%s\n' "$lines" | awk 'NF && !seen[$0]++')"
  touch "$gi"
  _strip_byrde_gitignore "$gi"
  printf '\n%s\n%s\n%s\n' "$BYRDE_GI_START" "$lines" "$BYRDE_GI_END" >>"$gi"
  echo "  ✓ ignored generated files in .gitignore: $(printf '%s' "$lines" | grep -v '^!' | tr '\n' ' ')"
}

# Reverse manage_editor_gitignore: drop the managed block (and legacy variants).
restore_editor_gitignore() {
  local project_root="$1"
  local gi="$project_root/.gitignore"
  [[ -f "$gi" ]] || return 0
  _strip_byrde_gitignore "$gi"
  echo "  ✓ removed byrde-agents ignore block from .gitignore"
}

print_intro() {
  local project_root="$1"
  local bar
  bar="$(printf '%*s' 68 '' | tr ' ' '=')"
  echo "$bar"
  echo "  $PROG_NAME · Byrde Agents  v$TOOL_VERSION"
  echo ""
  echo "  Bootstrap a project with Byrde Agents — installs rules, skills, MCP"
  echo "  servers and hooks, adapted to each agent harness you choose."
  echo ""
  printf '  %-16s %s\n' "Project Root" "$project_root"
  printf '  %-16s %s\n' "Agents Root" "$AGENTS_ROOT"
  printf '  %-16s %s\n' "Skills Source" "$SKILLS_DIR"
  printf '  %-16s %s\n' "Rules Source" "$RULES_DIR"
  echo "$bar"
  echo ""
}

print_summary() {
  local bar h
  bar="$(printf '%*s' 68 '' | tr ' ' '=')"
  echo ""
  echo "$bar"
  echo "  $PROG_NAME · Summary"
  echo "$bar"
  echo ""
  echo "  Installed for:"
  for h in $(harness_selected); do
    printf '    ✓ %-20s rules → %s\n' "$(harness_label "$h")" "$(harness_rule_where "$h" "*" | sed 's/section \*/sections/')"
    printf '      %-20s skills → %s/\n' "" "$(harness_skills_dir "$h")"
    if harness_supports_hooks "$h"; then
      printf '      %-20s hooks → %s\n' "" "$(harness_hook_file "$h")"
    fi
  done
  if harness_has claude; then
    echo "    ✓ Claude Code auto-memory → on; dir $AUTO_MEMORY_DIR (abs path in"
    echo "        settings.local.json), content git-tracked & shared with the team"
    echo "    ✓ Claude Code permissions → tool calls auto-approved (defaultMode:"
    echo "        auto, allow: [Edit, Write] in .claude/settings.json)"
  fi
  if harness_has codex; then
    echo ""
    echo "  Codex loads .codex/ only in a trusted project, and asks you to trust"
    echo "  each hook once (/hooks)."
  fi
  if harness_has antigravity; then
    echo ""
    echo "  Antigravity gets no hooks: its PostToolUse cannot add context."
  fi
  if harness_has opencode; then
    echo ""
    echo "  OpenCode: settings and MCP in .opencode/opencode.json; hooks are the"
    echo "  byrde-agents plugin (rules re-injection, rules kept through compaction,"
    echo "  allow-all). Works with OpenCode 1.18.29+ and 2.x."
  fi
  echo ""
  echo "  Optional next steps (they install for the same harnesses):"
  echo "    • .agents/scripts/setup/setup-github-project.sh  (pin a GitHub project board)"
  echo "    • .agents/scripts/setup/setup-jira.sh            (pin a Jira site + project)"
  echo "    • .agents/scripts/setup/setup-google-analytics.sh (pin a GA4 property)"
  echo "    • .agents/scripts/setup/setup-figma.sh           (Figma tool skill)"
  echo "    (GitHub source-control + MCP were just set up automatically.)"
  echo ""
  echo "  Change harnesses: .agents/scripts/init.sh --harness <list>"
  echo "  Verify with: .agents/scripts/doctor.sh"
  echo "  Undo with:   .agents/scripts/init.sh uninstall"
  echo "$bar"
}

# ─── Step 1: Choose harnesses ────────────────────────────────────────────────

# --harness value from the command line, if any.
HARNESS_ARG=""

# Decide which harnesses to install for: --harness > $BYRDE_HARNESSES > ask (on a
# terminal) > the saved choice > the default (opencode only). Exports BYRDE_HARNESSES so every
# later step — and the libs — agree on the answer for this run.
choose_harnesses() {
  echo "── Step 1/5: Harnesses ────────────────────────────────────────────"
  echo ""
  local current choice="" given="${HARNESS_ARG:-${BYRDE_HARNESSES:-}}" h i ans
  current="$(harness_saved)"
  [[ -n "$current" ]] || current="$HARNESS_DEFAULT"

  if [[ -n "$given" ]]; then
    choice="$(harness_parse "$given")"
    [[ -n "$choice" ]] || die "no known harness in '$given' (known: $HARNESS_ALL)"
  elif [[ -t 0 ]]; then
    echo "  Install and adapt the assets for which harnesses?"
    echo ""
    i=0
    for h in $HARNESS_ALL; do
      i=$((i + 1))
      case " $current " in *" $h "*) mark="x" ;; *) mark=" " ;; esac
      printf '    %d) [%s] %-12s %s\n' "$i" "$mark" "$h" "$(harness_label "$h")"
    done
    echo ""
    while :; do
      read -r -p "  Numbers or names, comma-separated, or 'all' [Enter keeps: ${current// /, }]: " ans || ans=""
      [[ -z "$ans" ]] && { choice="$current"; break; }
      choice="$(harness_parse "$ans")"
      [[ -n "$choice" ]] && break
      echo "  Pick at least one."
    done
    echo ""
  else
    choice="$current"
  fi

  BYRDE_HARNESSES="$choice"
  export BYRDE_HARNESSES
  for h in $choice; do echo "  ✓ $(harness_label "$h")"; done
  echo ""
}

# ─── Step 2: Install Rules ───────────────────────────────────────────────────

copy_rules() {
  local project_root="$1"

  echo "── Step 2/5: Install Rules ────────────────────────────────────────"
  echo ""

  if [[ ! -d "$RULES_DIR" ]]; then
    die "rules directory not found at $RULES_DIR"
  fi

  local file name h count=0
  for file in "$RULES_DIR"/*.md; do
    [[ -f "$file" ]] || continue
    name="$(basename "$file" .md)"
    # Older installs copied both formats into both dirs.
    rm -f "$project_root/.claude/rules/$name.mdc" "$project_root/.cursor/rules/$name.md"
    for h in $(harness_selected); do
      harness_rule_install "$project_root" "$h" "$file"
      printf '  %-24s → %s\n' "$name.md" "$(harness_rule_where "$h" "$name")"
    done
    for h in $(harness_unselected); do
      harness_rule_remove "$project_root" "$h" "$name"
    done
    count=$((count + 1))
  done

  echo ""
  echo "  ✓ $count rule(s) installed (includes the always-on workspace routing rule)"
  echo ""
}

# Generate the workspace repo map that the always-on workspace rule (installed by
# copy_rules) reads to route work. The flavour is resolved as:
#   BYRDE_WORKSPACE_MODE override > existing declared mode in the map (so a
#   re-run refreshes rather than re-guesses, and honours a hand-edited mode) >
#   auto-detect (multiple sibling repos ⇒ multi, else mono).
# Re-running init refreshes the map (auto fields update, `purpose` notes are
# preserved). Best-effort: needs jq + git.
generate_workspace_map() {
  echo "── Workspace map ──────────────────────────────────────────────────"
  echo ""
  if ! command -v jq >/dev/null 2>&1 || ! command -v git >/dev/null 2>&1; then
    echo "  ⚠ jq or git missing — skipping .workspace.agents.json"
    echo "    (re-run init.sh once jq + git are available)"
    echo ""
    return 0
  fi
  local mode origin
  if [[ -n "${BYRDE_WORKSPACE_MODE:-}" ]]; then
    mode="$BYRDE_WORKSPACE_MODE"; origin="forced"
  elif mode="$(workspace_declared_mode)" && [[ -n "$mode" ]]; then
    origin="preserved"
  else
    mode="mono"; [[ ${#SIBLING_REPOS[@]} -gt 0 ]] && mode="multi"; origin="auto-detected"
  fi
  case "$mode" in mono | multi) ;; *) echo "  ⚠ invalid BYRDE_WORKSPACE_MODE '$mode' — using auto"; mode="mono"; [[ ${#SIBLING_REPOS[@]} -gt 0 ]] && mode="multi"; origin="auto-detected" ;; esac

  workspace_generate "$mode"
  # (gitignore handled by manage_editor_gitignore — one byrde-agents block)
  echo "  ✓ wrote ${WORKSPACE_FILE#"$WORKSPACE_ROOT"/} (mode: $mode, $origin)"
  echo "    to change the flavour: edit \"mode\" in the map (or set BYRDE_WORKSPACE_MODE) and re-run init.sh"
  echo ""
  workspace_summary
  echo ""
}

# Register the account-wide GitHub MCP server when the workspace has GitHub repos.
# The always-on github-source-control rule (installed by copy_rules) drives it;
# the server is OAuth'd through the editor and carries no secrets. No-op (with a
# note) when there are no github.com remotes in the map, or when jq is missing.
register_github_mcp() {
  echo "── GitHub MCP ─────────────────────────────────────────────────────"
  echo ""
  if ! command -v jq >/dev/null 2>&1; then
    echo "  ⚠ jq missing — skipping GitHub MCP registration"
    echo ""
    return 0
  fi
  if workspace_has_github_remote; then
    # Before the merge, not after: Claude Code skips this project's settings
    # entirely while the workspace is untrusted, so the approval mcp_merge_github
    # writes would be inert and its own warning would fire on a fresh install.
    # Best-effort: a machine with no ~/.claude.json yet must not abort the install.
    if harness_has claude; then grant_workspace_trust "$WORKSPACE_ROOT" || true; fi
    mcp_merge_github "$WORKSPACE_ROOT"
    echo "    account-wide (works across all your repos). Claude Code fetches the"
    echo "    token live from 'gh auth token' on each connect (headersHelper) —"
    echo "    nothing on disk, no env var to set; just be logged in: gh auth login."
    echo "    (The other harnesses have no headersHelper — export"
    echo "    GITHUB_PERSONAL_ACCESS_TOKEN=\"\$(gh auth token)\" for them.)"
  else
    echo "  (no github.com remotes in the workspace map — skipping GitHub MCP)"
  fi
  echo ""
}

# Migrate older installs: github-source-control used to be a rendered, per-repo
# tool SKILL. It is now an always-on RULE (installed by copy_rules), so drop any
# stale skill copies + manifest entry left over from the old setup-github.sh.
migrate_github_source_control() {
  local project_root="$1" found=0 d
  for d in "$AGENTS_ROOT/skills/github-source-control" \
           "$project_root/.claude/skills/github-source-control" \
           "$project_root/.cursor/skills/github-source-control"; do
    [[ -e "$d" ]] && { rm -rf "$d"; found=1; }
  done
  if command -v jq >/dev/null 2>&1 && manifest_has github-source-control 2>/dev/null; then
    manifest_remove github-source-control; found=1
  fi
  [[ "$found" -eq 1 ]] && echo "  ✓ migrated github-source-control (old skill → always-on rule)"
  return 0
}

# ─── Step 2: Install Skills ─────────────────────────────────────────────────

copy_skills() {
  local project_root="$1"

  echo "── Step 3/5: Install Skills ───────────────────────────────────────"
  echo ""

  if [[ ! -d "$SKILLS_DIR" ]]; then
    die "skills directory not found at $SKILLS_DIR"
  fi

  # Seed each entry in skills/ EXCEPT the rendered/vendored tool-skill dirs:
  # those are per-project and owned by the setup-*.sh scripts (which mirror them
  # themselves). Seeding them here would copy the shared checkout's staging —
  # which, in multi-repo mode, holds whichever repo last configured it. Every
  # harness except Claude Code reads .agents/skills/ in place, so for them this
  # is usually a no-op (see lib/harness.sh).
  local entry name h
  for entry in "$SKILLS_DIR"/*; do
    [[ -e "$entry" ]] || continue
    name="$(basename "$entry")"
    if [[ -d "$entry" ]] && is_tool_skill "$name"; then
      continue
    fi
    for h in $(harness_selected); do
      harness_skill_install "$project_root" "$h" "$entry"
    done
    for h in $(harness_unselected); do
      harness_skill_remove "$project_root" "$h" "$name" "$entry"
    done
  done

  for h in $(harness_selected); do
    printf '  practice skills → %-16s (%s)\n' "$(harness_skills_dir "$h")/" "$(harness_label "$h")"
  done
  echo "  (tool skills are installed by setup-*.sh scripts)"
  echo ""
  echo "  ✓ Skills installed."
  echo ""
  # The generated files are rebuilt from .agents — keep them out of git.
  manage_editor_gitignore "$project_root"
  echo ""
}

# ─── Step 3: Claude Code auto-memory (on by default) ─────────────────────────

enable_auto_memory() {
  local project_root="$1"

  local abs_dir="$project_root/$AUTO_MEMORY_DIR"

  echo "── Step 4/5: Claude Code auto-memory ──────────────────────────────"
  echo ""
  echo "  Turning ON Claude Code's built-in auto-memory (the default) and"
  echo "  pinning its directory to an absolute path in settings.local.json"
  echo "  (machine-specific). The memory CONTENT under $AUTO_MEMORY_DIR/ is"
  echo "  git-tracked and shared across the team."
  echo ""
  mkdir -p "$abs_dir"
  set_auto_memory "$project_root" true              # enabled flag → settings.json
  set_auto_memory_dir_local "$project_root" "$abs_dir"
  echo ""
}

# Take Claude Code's settings back out when it is no longer selected.
revert_claude_settings() {
  local project_root="$1"
  [[ -f "$project_root/.claude/settings.json" || -f "$project_root/.claude/settings.local.json" ]] || return 0
  echo "── Claude Code not selected — reverting its settings ──────────────"
  echo ""
  del_allow_all_tools "$project_root"
  del_allow_all_hook "$project_root"
  del_rules_reinject_hook "$project_root"
  del_auto_memory "$project_root"
  del_auto_memory_dir_local "$project_root"
  echo ""
}

# ─── Step 5: Permissions and hooks (every harness) ───────────────────────────

enable_allow_all_tools() {
  local project_root="$1"

  echo "── Step 5/5: Permissions and hooks ────────────────────────────────"
  echo ""
  echo "  Every tool call is approved with no prompt, and the rules are"
  echo "  re-injected every ${BYRDE_RULES_REINJECT_EVERY:-12} tool calls, in each harness that has hooks."
  echo "  Multi-select questions are not permission-gated and still prompt."
  echo ""
  local h
  for h in $HARNESS_ALL; do
    if [[ "$h" == "claude" ]]; then
      if harness_has claude; then
        set_allow_all_tools "$project_root"
        set_allow_all_hook "$project_root"
        set_rules_reinject_hook "$project_root"
      fi
      continue
    fi
    harness_supports_hooks "$h" || continue
    if harness_has "$h"; then
      harness_hooks_install "$project_root" "$h"
      echo "  ✓ allow-all + rules re-injection hooks → $(harness_hook_file "$h") ($(harness_label "$h"))"
      [[ "$h" == "opencode" ]] && \
        echo "    settings → .opencode/opencode.json (permission: allow, unless you set your own)"
    else
      harness_hooks_remove "$project_root" "$h"
    fi
  done
  if harness_has antigravity; then
    echo "  – Antigravity: no hooks (its PostToolUse cannot add context)"
  fi
  echo ""
}

# ─── Uninstall ───────────────────────────────────────────────────────────────

# Remove the rules init installed: every rule, from every harness — not only the
# selected ones, so a harness dropped earlier is cleaned up too.
remove_rules() {
  local project_root="$1"
  echo "── Removing rules ─────────────────────────────────────────────────"
  echo ""
  [[ -d "$RULES_DIR" ]] || { echo "  (no rules source — skipping)"; echo ""; return 0; }
  local file name h count=0
  for file in "$RULES_DIR"/*.md; do
    [[ -f "$file" ]] || continue
    name="$(basename "$file" .md)"
    for h in $HARNESS_ALL; do
      HARNESS_PURGE=1 harness_rule_remove "$project_root" "$h" "$name"
    done
    # Older installs copied both formats into both dirs.
    rm -f "$project_root/.claude/rules/$name.mdc" "$project_root/.cursor/rules/$name.md"
    printf '  removed  %s\n' "$name"
    count=$((count + 1))
  done
  rmdir "$project_root/.cursor/rules" "$project_root/.claude/rules" 2>/dev/null || true
  echo ""
  echo "  ✓ $count rule(s) removed from every harness"
  echo ""
}

# Remove the skill copies init made, from every harness. Mirrors copy_skills.
remove_skills() {
  local project_root="$1"
  echo "── Removing skills ────────────────────────────────────────────────"
  echo ""
  [[ -d "$SKILLS_DIR" ]] || { echo "  (no skills source — skipping)"; echo ""; return 0; }
  local entry name h
  for entry in "$SKILLS_DIR"/*; do
    [[ -e "$entry" ]] || continue
    name="$(basename "$entry")"
    # Tool skills are owned by the setup-*.sh scripts (and their uninstall) —
    # init never seeded them, so it must not remove them here.
    if [[ -d "$entry" ]] && is_tool_skill "$name"; then
      continue
    fi
    for h in $HARNESS_ALL; do
      harness_skill_remove "$project_root" "$h" "$name" "$entry"
    done
    printf '  removed  %s\n' "$name"
  done
  echo ""
  echo "  ✓ Skill copies removed (the .agents/skills/ source stays)"
  echo ""
}

uninstall() {
  local project_root="$1"
  local bar
  bar="$(printf '%*s' 68 '' | tr ' ' '=')"
  echo "$bar"
  echo "  $PROG_NAME · Uninstall  v$TOOL_VERSION"
  echo ""
  echo "  Removes the rules, skills and hooks init.sh installed, for every"
  echo "  harness, plus the autoMemoryEnabled flag and the allow-all permission"
  echo "  mode it wrote. Does NOT touch tool skills' MCP/hooks config — run each"
  echo "  setup-*.sh uninstall for those."
  echo ""
  printf '  %-16s %s\n' "Project Root" "$project_root"
  echo "$bar"
  echo ""

  remove_rules "$project_root"
  remove_skills "$project_root"

  echo "── Reverting permissions and hooks ────────────────────────────────"
  echo ""
  del_allow_all_tools "$project_root"
  del_allow_all_hook "$project_root"
  del_rules_reinject_hook "$project_root"
  local h
  for h in $HARNESS_ALL; do
    [[ "$h" == "claude" ]] || harness_hooks_remove "$project_root" "$h"
  done
  echo ""

  echo "── Reverting auto-memory ──────────────────────────────────────────"
  echo ""
  del_auto_memory "$project_root"
  del_auto_memory_dir_local "$project_root"
  restore_editor_gitignore "$project_root"
  # The workspace + github-source-control rules are removed by remove_rules (they
  # ship in .agents/rules/); drop the generated map and the GitHub MCP too.
  [[ -f "$WORKSPACE_FILE" ]] && { rm -f "$WORKSPACE_FILE"; echo "  ✓ removed ${WORKSPACE_FILE##*/}"; }
  if command -v jq >/dev/null 2>&1; then
    echo "── Removing GitHub MCP ──"
    mcp_remove_github "$WORKSPACE_ROOT"
    revoke_workspace_trust "$WORKSPACE_ROOT"
  fi
  echo ""

  echo "$bar"
  echo "  Done. Rules, skills, auto-memory, and the permission mode removed."
  echo "  Tool skills installed by setup-*.sh are untouched — uninstall those"
  echo "  with their own scripts (e.g. setup-figma.sh uninstall)."
  echo "$bar"
}

# ─── Main ────────────────────────────────────────────────────────────────────

main() {
  # --harness LIST (or --harness=LIST) chooses the harnesses without asking.
  local args=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --harness | --harnesses) HARNESS_ARG="${2:-}"; shift 2 || shift ;;
      --harness=* | --harnesses=*) HARNESS_ARG="${1#*=}"; shift ;;
      *) args+=("$1"); shift ;;
    esac
  done
  set -- ${args[@]+"${args[@]}"}

  case "${1:-}" in
    -h | --help | help)
      echo "$PROG_NAME · Byrde Agents v$TOOL_VERSION"
      echo ""
      echo "Usage:"
      echo "  cd /your/project && $0 [--harness LIST]   # install"
      echo "  cd /your/project && $0 uninstall          # remove what install wrote"
      echo "  cd /your/project && $0 --help"
      echo ""
      echo "Options:"
      echo "  --harness LIST   Harnesses to install and adapt assets for, comma-separated."
      echo "                   Names: $HARNESS_ALL, or 'all'."
      echo "                   Numbers 1-6 select by position. Also --harness=LIST, --harnesses."
      echo "                   Without it, a terminal run asks (Enter keeps the saved"
      echo "                   choice, or '$HARNESS_DEFAULT' on a first run); a non-interactive run"
      echo "                   uses the saved choice, or '$HARNESS_DEFAULT'. Fewer harnesses than"
      echo "                   last time removes what the dropped ones had."
      echo "  uninstall        Remove rules, skills, MCP, hooks and settings from every"
      echo "                   harness (alias: remove). Tool skills from setup-*.sh stay."
      echo ""
      echo "Environment:"
      echo "  BYRDE_HARNESSES             Same as --harness (the flag wins)."
      echo "  BYRDE_WORKSPACE_MODE        mono | multi — force the workspace flavour."
      echo "  BYRDE_RULES_REINJECT_EVERY  Re-inject the rules every N tool calls (default 12, 0 = off)."
      echo ""
      echo "The choice is saved as \"harnesses\" in .workspace.agents.json and reused by"
      echo "re-runs and the setup-*.sh scripts. Paths per harness: scripts/lib/harness.sh."
      exit 0
      ;;
    uninstall | remove)
      resolve_layout   # sets WORKSPACE_ROOT / WORKSPACE_FILE for map + MCP removal
      uninstall "$PROJECT_ROOT"
      exit 0
      ;;
  esac

  # Classify the run (snaps PROJECT_ROOT to the git repo root). resolve_layout
  # repoints SKILLS_DIR at a per-project home; init seeds the SHARED practice
  # skills, so restore the .agents source afterward.
  resolve_layout
  SKILLS_DIR="$AGENTS_ROOT/skills"

  local project_root="$PROJECT_ROOT"

  print_intro "$project_root"

  choose_harnesses
  # The map is written first so the choice is saved before anything reads it.
  generate_workspace_map
  harness_save "$BYRDE_HARNESSES"
  copy_rules "$project_root"
  copy_skills "$project_root"
  migrate_github_source_control "$project_root"
  register_github_mcp
  if harness_has claude; then
    enable_auto_memory "$project_root"
  else
    revert_claude_settings "$project_root"
  fi
  enable_allow_all_tools "$project_root"

  print_summary
}

# Run only when executed. The test suite sources this file to exercise the
# settings and hook helpers on their own.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
