#!/usr/bin/env bash
# Bootstrap a host project with Byrde Agents.
#
# Copies rules and skills into the project's editor directories so the
# Claude and Cursor agents can pick them up, and turns ON Claude Code's
# built-in auto-memory (the default). Optional setup steps (GitHub tool
# skills, the Figma tool skill, mempalace memory) are run separately as their
# own scripts. setup-memory.sh turns auto-memory OFF — mempalace replaces
# Claude's native memory — and turns it back ON when uninstalled.
#
# Run from the repository/project root you want to initialise.
# Writes:
#   - .cursor/rules/          — global AI rules for Cursor
#   - .claude/rules/          — global AI rules for Claude Code
#   - .cursor/skills/         — agent skills copied into Cursor dir
#   - .claude/skills/         — agent skills copied into Claude Code dir
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
#   cd /path/to/project && /path/to/init.sh              # install
#   cd /path/to/project && /path/to/init.sh uninstall    # remove what install wrote
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
# unambiguous. setup-memory turns the flag off (mempalace takes over).
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
# fenced block: the editor dirs (.claude/, .cursor/), the project MCP config
# (.mcp.json), the workspace map (.workspace.agents.json), and the per-branch
# worktree dir (.worktrees/). init.sh and the setup-*.sh scripts produce these
# from the .agents submodule, so they're regenerable — not worth committing. The
# block re-includes .claude/memory/ ahead of the blanket ignores; the shared
# memory/ dir sits at the project root — NOT under .claude/ — so it's never
# blocked either way. Upserts the file and rewrites the block, so it's idempotent.
manage_editor_gitignore() {
  local project_root="$1"
  local gi="$project_root/.gitignore"
  local map
  map="$(basename "$WORKSPACE_FILE")"   # .workspace.agents.json
  touch "$gi"
  _strip_byrde_gitignore "$gi"
  printf '\n%s\n.claude/*\n!.claude/memory/\n.worktrees/\n.claude/\n.cursor/\n.mcp.json\n%s\n%s\n' \
    "$BYRDE_GI_START" "$map" "$BYRDE_GI_END" >>"$gi"
  echo "  ✓ ignored .claude/, .cursor/, .mcp.json, .worktrees/, $map in .gitignore"
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
  echo "  Bootstrap a project with Byrde Agents — installs rules and skills"
  echo "  into your editor directories so Claude Code and Cursor can pick"
  echo "  them up."
  echo ""
  printf '  %-16s %s\n' "Project Root" "$project_root"
  printf '  %-16s %s\n' "Agents Root" "$AGENTS_ROOT"
  printf '  %-16s %s\n' "Skills Source" "$SKILLS_DIR"
  printf '  %-16s %s\n' "Rules Source" "$RULES_DIR"
  echo "$bar"
  echo ""
}

print_summary() {
  local bar
  bar="$(printf '%*s' 68 '' | tr ' ' '=')"
  echo ""
  echo "$bar"
  echo "  $PROG_NAME · Summary"
  echo "$bar"
  echo ""
  echo "  Installed:"
  echo "    ✓ Rules   → .cursor/rules/  and  .claude/rules/"
  echo "    ✓ Skills  → .cursor/skills/ and  .claude/skills/"
  echo "    ✓ Claude Code auto-memory → on; dir $AUTO_MEMORY_DIR (abs path in"
  echo "        settings.local.json), content git-tracked & shared with the team"
  echo "    ✓ Claude Code permissions → tool calls auto-approved (defaultMode:"
  echo "        auto, allow: [Edit, Write] in .claude/settings.json)"
  echo ""
  echo "  Optional next steps:"
  echo "    • .agents/scripts/setup/setup-github-project.sh  (pin a GitHub project board)"
  echo "    • .agents/scripts/setup/setup-jira.sh            (pin a Jira site + project)"
  echo "    • .agents/scripts/setup/setup-figma.sh           (Figma tool skill)"
  echo "    • .agents/scripts/setup/setup-memory.sh          (mempalace memory; turns auto-memory off)"
  echo "    (GitHub source-control + MCP were just set up automatically.)"
  echo ""
  echo "  Verify with: .agents/scripts/doctor.sh"
  echo "  Undo with:   .agents/scripts/init.sh uninstall"
  echo "$bar"
}

# ─── Step 1: Install Rules ───────────────────────────────────────────────────

copy_rules() {
  local project_root="$1"

  echo "── Step 1/4: Install Rules ────────────────────────────────────────"
  echo ""

  if [[ ! -d "$RULES_DIR" ]]; then
    die "rules directory not found at $RULES_DIR"
  fi

  local cursor_rules="$project_root/.cursor/rules"
  local claude_rules="$project_root/.claude/rules"

  mkdir -p "$cursor_rules" "$claude_rules"

  local count=0
  for file in "$RULES_DIR"/*; do
    [[ -f "$file" ]] || continue

    local name
    name="$(basename "$file")"

    cp "$file" "$cursor_rules/$name"
    cp "$file" "$claude_rules/$name"

    printf '  %-24s → .cursor/rules/%s\n' "$name" "$name"
    printf '  %-24s → .claude/rules/%s\n' "" "$name"
    count=$((count + 1))
  done

  echo ""
  echo "  ✓ $count rule(s) installed to .cursor/rules/ and .claude/rules/"
  echo "    (includes the always-on workspace routing rule)"
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
    grant_workspace_trust "$WORKSPACE_ROOT"
    mcp_merge_github "$WORKSPACE_ROOT"
    echo "    account-wide (works across all your repos). Claude Code fetches the"
    echo "    token live from 'gh auth token' on each connect (headersHelper) —"
    echo "    nothing on disk, no env var to set; just be logged in: gh auth login."
    echo "    (Cursor has no headersHelper — export GITHUB_PERSONAL_ACCESS_TOKEN for it.)"
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

  echo "── Step 2/4: Install Skills ───────────────────────────────────────"
  echo ""

  if [[ ! -d "$SKILLS_DIR" ]]; then
    die "skills directory not found at $SKILLS_DIR"
  fi

  local cursor_skills="$project_root/.cursor/skills"
  local claude_skills="$project_root/.claude/skills"

  mkdir -p "$cursor_skills" "$claude_skills"

  # Seed each entry in skills/ EXCEPT the rendered/vendored tool-skill dirs:
  # those are per-project and owned by the setup-*.sh scripts (which mirror them
  # into the editor dirs themselves). Seeding them here would copy the shared
  # checkout's staging — which, in multi-repo mode, holds whichever repo last
  # configured it. We replace each dest entry wholesale so this stays idempotent.
  local entry name
  for entry in "$SKILLS_DIR"/*; do
    [[ -e "$entry" ]] || continue
    name="$(basename "$entry")"
    if [[ -d "$entry" ]] && is_tool_skill "$name"; then
      continue
    fi
    rm -rf "${cursor_skills:?}/$name" "${claude_skills:?}/$name"
    cp -R "$entry" "$cursor_skills/$name"
    cp -R "$entry" "$claude_skills/$name"
  done

  echo "  practice skills/ → .cursor/skills/ and .claude/skills/"
  echo "  (tool skills are installed by setup-github-project.sh / setup-figma.sh / setup-memory.sh)"
  echo ""
  echo "  ✓ Skills installed."
  echo ""
  # The editor dirs are generated from .agents — keep them out of git.
  manage_editor_gitignore "$project_root"
  echo ""
}

# ─── Step 3: Claude Code auto-memory (on by default) ─────────────────────────

enable_auto_memory() {
  local project_root="$1"

  local abs_dir="$project_root/$AUTO_MEMORY_DIR"

  echo "── Step 3/4: Claude Code auto-memory ──────────────────────────────"
  echo ""
  echo "  Turning ON Claude Code's built-in auto-memory (the default) and"
  echo "  pinning its directory to an absolute path in settings.local.json"
  echo "  (machine-specific). The memory CONTENT under $AUTO_MEMORY_DIR/ is"
  echo "  git-tracked and shared across the team. setup-memory.sh turns the"
  echo "  flag off — mempalace replaces it — and back on when uninstalled."
  echo ""
  mkdir -p "$abs_dir"
  set_auto_memory "$project_root" true              # enabled flag → settings.json
  set_auto_memory_dir_local "$project_root" "$abs_dir"
  echo ""
}

# ─── Step 4: Claude Code permissions (allow all tool calls) ───────────────────

enable_allow_all_tools() {
  local project_root="$1"

  echo "── Step 4/4: Claude Code permissions ──────────────────────────────"
  echo ""
  echo "  Auto-approving tool calls for Claude Code in this project:"
  echo "  permissions.defaultMode = auto, permissions.allow = [Edit, Write],"
  echo "  plus an allow-all PreToolUse hook, in .claude/settings.json. Every"
  echo "  tool call is approved with no prompt (the hook bypasses auto mode's"
  echo "  safety classifier). Multi-select questions (AskUserQuestion) are not"
  echo "  permission-gated and still prompt."
  echo ""
  set_allow_all_tools "$project_root"
  set_allow_all_hook "$project_root"
  set_rules_reinject_hook "$project_root"
  echo ""
}

# ─── Uninstall ───────────────────────────────────────────────────────────────

# Remove the rules init copied: one dest per file in rules/, in both editor dirs.
remove_rules() {
  local project_root="$1"
  echo "── Removing rules ─────────────────────────────────────────────────"
  echo ""
  [[ -d "$RULES_DIR" ]] || { echo "  (no rules source — skipping)"; echo ""; return 0; }
  local file name count=0
  for file in "$RULES_DIR"/*; do
    [[ -f "$file" ]] || continue
    name="$(basename "$file")"
    rm -f "$project_root/.cursor/rules/$name" "$project_root/.claude/rules/$name"
    printf '  removed  %s\n' "$name"
    count=$((count + 1))
  done
  # Drop the rule dirs if init emptied them.
  rmdir "$project_root/.cursor/rules" "$project_root/.claude/rules" 2>/dev/null || true
  echo ""
  echo "  ✓ $count rule(s) removed from .cursor/rules/ and .claude/rules/"
  echo ""
}

# Remove the skills init copied: one dest per entry in skills/, in both editor
# dirs. Mirrors copy_skills (which copies the whole skills/ tree).
remove_skills() {
  local project_root="$1"
  echo "── Removing skills ────────────────────────────────────────────────"
  echo ""
  [[ -d "$SKILLS_DIR" ]] || { echo "  (no skills source — skipping)"; echo ""; return 0; }
  local entry name dest
  for entry in "$SKILLS_DIR"/*; do
    [[ -e "$entry" ]] || continue
    name="$(basename "$entry")"
    # Tool skills are owned by the setup-*.sh scripts (and their uninstall) —
    # init never seeded them, so it must not remove them here.
    if [[ -d "$entry" ]] && is_tool_skill "$name"; then
      continue
    fi
    for dest in "$project_root/.cursor/skills" "$project_root/.claude/skills"; do
      rm -rf "${dest:?}/$name"
    done
    printf '  removed  %s\n' "$name"
  done
  rmdir "$project_root/.cursor/skills" "$project_root/.claude/skills" 2>/dev/null || true
  echo ""
  echo "  ✓ Skills removed from .cursor/skills/ and .claude/skills/"
  echo ""
}

uninstall() {
  local project_root="$1"
  local bar
  bar="$(printf '%*s' 68 '' | tr ' ' '=')"
  echo "$bar"
  echo "  $PROG_NAME · Uninstall  v$TOOL_VERSION"
  echo ""
  echo "  Removes the rules and skills init.sh copied into your editor dirs,"
  echo "  the autoMemoryEnabled flag, and the allow-all permission mode it"
  echo "  wrote. Does NOT touch tool skills' MCP/hooks config — run each"
  echo "  setup-*.sh uninstall for those."
  echo ""
  printf '  %-16s %s\n' "Project Root" "$project_root"
  echo "$bar"
  echo ""

  remove_rules "$project_root"
  remove_skills "$project_root"

  echo "── Reverting Claude Code permissions ──────────────────────────────"
  echo ""
  del_allow_all_tools "$project_root"
  del_allow_all_hook "$project_root"
  del_rules_reinject_hook "$project_root"
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
  echo "  with their own scripts (e.g. setup-memory.sh uninstall)."
  echo "$bar"
}

# ─── Main ────────────────────────────────────────────────────────────────────

main() {
  case "${1:-}" in
    -h | --help | help)
      echo "$PROG_NAME · Byrde Agents v$TOOL_VERSION"
      echo ""
      echo "Usage:"
      echo "  cd /your/project && $0              # install rules + skills, auto-memory on"
      echo "  cd /your/project && $0 uninstall    # remove what install wrote"
      echo ""
      echo "Install copies .agents/rules/ and .agents/skills/ into .cursor/ and"
      echo ".claude/, and configures Claude Code's built-in auto-memory:"
      echo "autoMemoryEnabled: true in .claude/settings.json, and an absolute"
      echo "autoMemoryDirectory (<project>/memory) in settings.local.json."
      echo "It also re-includes memory/ in .gitignore (if ignored) so the memory"
      echo "content is git-tracked and shared across the team, and auto-approves"
      echo "Claude Code tool calls (permissions.defaultMode: auto, permissions.allow:"
      echo "[Edit, Write] in .claude/settings.json)."
      echo ""
      echo "Uninstall removes those copied rules/skills, the auto-memory settings,"
      echo "and the permission mode. It does not touch MCP/hooks config from the"
      echo "setup-*.sh scripts."
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

  copy_rules "$project_root"
  copy_skills "$project_root"
  migrate_github_source_control "$project_root"
  generate_workspace_map
  register_github_mcp
  enable_auto_memory "$project_root"
  enable_allow_all_tools "$project_root"

  print_summary
}

# Run only when executed. The test suite sources this file to exercise the
# settings and hook helpers on their own.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
