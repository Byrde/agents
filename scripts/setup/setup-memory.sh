#!/usr/bin/env bash
# Configure the mempalace memory system for Claude Code or Cursor.
#
# Installs mempalace (if not present), initialises a project-local palace,
# registers the MCP server + auto-save hooks for the ONE editor you choose
# (running more than one writer on a palace drifts its index), installs the
# `memory` skill + rule, and configures git so the palace is portable.
#
# Run from the repository/project root you want to configure (current working directory).
# Writes:
#   - .mempalace/                     — project-local palace data
#   - .mempalace/hooks/               — save and precompact hook scripts
#   - .mempalaceignore                — ignore patterns for mining (node_modules, etc.)
#   - .gitignore                      — commit chroma.sqlite3 (portable data);
#                                       ignore the derived <uuid>/ vector index +
#                                       backups (rebuilt locally via `repair`)
#   - .agents/skills/memory/SKILL.md  — skill for using mempalace + Claude memory
#   - .claude|.cursor/skills/memory/  — skill mirrored into the editor dirs
#   - .claude/rules/memory.md         — rule: how aggressively to use memory
#   - .cursor/rules/memory.mdc        — same rule, Cursor format
#   - .cursor/mcp.json + .mcp.json    — project MCP (Cursor + Claude Code)
#   - .cursor/hooks.json + .claude/settings.local.json — hooks (both editors)
#   - .claude/settings.json           — autoMemoryEnabled: false (mempalace
#                                       replaces Claude Code's native memory)
#
# Git portability: chroma.sqlite3 is the committed ground truth; the vector
# index is rebuilt from it locally (`setup-memory.sh repair`) on checkout.
#
# Does not modify $HOME.
#
# Usage:
#   cd /path/to/project && /path/to/setup-memory.sh              # full setup
#   cd /path/to/project && /path/to/setup-memory.sh uninstall    # tear down
#
# Requires: python3, jq
# Compatible with Bash 3.2 (macOS): no mapfile/readarray.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENTS_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# Resolve mono- vs multi-repo layout (sets SKILLS_DIR + MANIFEST_FILE) BEFORE
# sourcing the manifest helper, which reads MANIFEST_FILE.
# shellcheck source=lib/layout.sh
. "$SCRIPT_DIR/../lib/layout.sh"
resolve_layout
# shellcheck source=lib/manifest.sh
. "$SCRIPT_DIR/../lib/manifest.sh"

TOOL_VERSION="0.1.0"
PROG_NAME="$(basename "${BASH_SOURCE[0]}")"
MEMPALACE_PACKAGE="mempalace"
MEMPALACE_REPO="https://github.com/milla-jovovich/mempalace"

# ─── Utilities ───────────────────────────────────────────────────────────────

die() {
  echo "error: $*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing required command: $1 (install or add to PATH)"
}

# Toggle Claude Code's built-in auto-memory in .claude/settings.json.
# mempalace replaces Claude's native memory, so install sets this to false;
# uninstall sets it back to true (Claude Code's default). jq is required by
# this script, so it is always available here.
set_auto_memory() {
  local project_root="$1" value="$2"  # value: true | false
  local settings="$project_root/.claude/settings.json"
  mkdir -p "$(dirname "$settings")"
  local tmp
  tmp="$(mktemp)"
  if [[ -f "$settings" ]]; then
    jq --argjson v "$value" '.autoMemoryEnabled = $v' "$settings" >"$tmp" \
      || die "jq failed on $settings (invalid JSON?)"
  else
    jq -n --argjson v "$value" '{autoMemoryEnabled: $v}' >"$tmp"
  fi
  mv "$tmp" "$settings"
  echo "autoMemoryEnabled=$value → $settings"
}

print_intro() {
  local project_root="$1"
  local bar
  bar="$(printf '%*s' 68 '' | tr ' ' '=')"
  echo "$bar"
  echo "  $PROG_NAME · Byrde Agents  v$TOOL_VERSION"
  echo ""
  echo "  Configure the mempalace memory system for this project."
  echo "  Installs mempalace, initialises a project-local palace, and"
  echo "  registers the MCP server for both Cursor and Claude Code."
  echo ""
  printf '  %-16s %s\n' "Project Root" "$project_root"
  printf '  %-16s %s\n' "Layout" "$(layout_describe)"
  printf '  %-16s %s\n' "Python" "$(resolve_python)"
  printf '  %-16s %s\n' "Repo" "$MEMPALACE_REPO"
  echo "$bar"
  echo ""
}

# ─── Python / mempalace helpers ──────────────────────────────────────────────

# Returns 0 if the Python binary at $1 is compatible with mempalace's chromadb
# dependency, 1 otherwise.
#
# Strategy:
#   1. If chromadb is already installed for this interpreter, do a live import
#      probe.  -W error::UserWarning turns pydantic's "not compatible with
#      Python 3.14+" warning into a hard failure so the probe is accurate.
#   2. If chromadb is not installed yet, fall back to a version check.
#      Current chromadb / pydantic-v1 does not support Python >= 3.14.
python_is_mempalace_compat() {
  local py="$1"
  if "$py" -W error::UserWarning -c "import chromadb" 2>/dev/null; then
    return 0
  fi
  # chromadb not installed yet — use version as a proxy.
  "$py" -c "import sys; sys.exit(0 if sys.version_info < (3, 14) else 1)" 2>/dev/null
}

# Resolve an appropriate Python interpreter for mempalace.
#
# Prefers version-specific interpreters (3.13 → 3.12 → 3.11 → 3.10) over the
# generic python3 symlink so that a system python3 that happens to resolve to
# 3.14 does not block setup.  Falls back to python3/python only after the
# version-specific names are exhausted.
#
# Each candidate is tested with python_is_mempalace_compat() before selection.
# If no compatible interpreter is found, the script exits with an actionable
# error message.
resolve_python() {
  # Strip any active virtualenv/conda from PATH so we always target the system
  # install — the same interpreter must be used for the MCP server at runtime.
  local search_path="$PATH"
  if [[ -n "${VIRTUAL_ENV:-}" || -n "${CONDA_PREFIX:-}" ]]; then
    search_path="$(printf '%s' "$PATH" \
      | tr ':' '\n' \
      | grep -v "${VIRTUAL_ENV:-__none__}" \
      | grep -v "${CONDA_PREFIX:-__none__}" \
      | tr '\n' ':')"
  fi

  # Build an ordered candidate list.  Version-specific names come first so we
  # select the newest *compatible* interpreter rather than whatever python3
  # symlinks to (which may be 3.14+).
  local -a raw=()
  local c name
  for name in python3.13 python3.12 python3.11 python3.10 python3 python; do
    c="$(PATH="$search_path" command -v "$name" 2>/dev/null)" || true
    [[ -n "$c" ]] && raw+=("$c")
  done

  [[ ${#raw[@]} -gt 0 ]] || die "python3 not found in PATH"

  # Deduplicate by resolved real path; drop venv-internal interpreters.
  local -a candidates=()
  local -a seen_real=()
  local py real_py already item
  for py in "${raw[@]}"; do
    real_py="$(readlink -f "$py" 2>/dev/null || echo "$py")"
    if [[ "$real_py" == */envs/* || "$real_py" == */.venv/* || "$real_py" == */venv/* ]]; then
      continue
    fi
    already=false
    for item in ${seen_real[@]+"${seen_real[@]}"}; do
      [[ "$item" == "$real_py" ]] && already=true && break
    done
    if [[ "$already" == false ]]; then
      seen_real+=("$real_py")
      candidates+=("$py")
    fi
  done

  [[ ${#candidates[@]} -gt 0 ]] \
    || die "all found Python interpreters appear to be inside a virtualenv — install a system python first"

  # Pick the first candidate that passes the compatibility probe.
  local chosen="" py_ver
  local -a incompatible=()
  for py in "${candidates[@]}"; do
    py_ver="$("$py" --version 2>&1 | awk '{print $2}')"
    if python_is_mempalace_compat "$py"; then
      chosen="$py"
      break
    else
      incompatible+=("$py ($py_ver)")
    fi
  done

  if [[ -n "$chosen" ]]; then
    if [[ ${#incompatible[@]} -gt 0 ]]; then
      echo "note: skipped Python versions incompatible with chromadb: ${incompatible[*]}" >&2
      echo "      (pydantic-v1 does not support Python >= 3.14)" >&2
    fi
    echo "$chosen"
    return 0
  fi

  # Nothing compatible found — give the user a clear path forward.
  local tried="${incompatible[*]:-none}"
  die "no compatible Python interpreter found for mempalace.
mempalace uses chromadb, which requires Python < 3.14 (pydantic-v1 incompatibility).
Tried: $tried
Fix: install Python 3.12 or 3.13, then re-run this script.
  brew install python@3.13   # recommended
  brew install python@3.12"
}

check_mempalace_installed() {
  local py="$1"
  "$py" -c "import mempalace" 2>/dev/null
}

get_mempalace_version() {
  local py="$1"
  "$py" -c "import mempalace; print(mempalace.__version__)" 2>/dev/null || echo "unknown"
}

# Install mempalace globally, trying pip → uv → ensurepip+pip in order.
# Always targets the system interpreter; never installs into a virtualenv.
install_mempalace() {
  local py="$1"

  # Deactivate any virtualenv for the install subprocess so pip/uv target the
  # system site-packages. We already resolved $py to the system interpreter.
  local -x VIRTUAL_ENV="" CONDA_PREFIX=""

  # Strategy 1: pip (--break-system-packages handles PEP 668 externally-managed envs)
  if "$py" -m pip --version >/dev/null 2>&1; then
    echo "Installing mempalace globally via pip …"
    "$py" -m pip install --quiet --break-system-packages "$MEMPALACE_PACKAGE" \
      || die "pip install mempalace failed"
    verify_import "$py"
    return 0
  fi

  # Strategy 2: uv (--system forces global site-packages)
  if command -v uv >/dev/null 2>&1; then
    echo "Installing mempalace globally via uv …"
    uv pip install --system --python "$py" "$MEMPALACE_PACKAGE" \
      || die "uv pip install mempalace failed"
    verify_import "$py"
    return 0
  fi

  # Strategy 3: bootstrap pip via ensurepip, then install
  echo "Neither pip nor uv found. Attempting to bootstrap pip via ensurepip …"
  if "$py" -m ensurepip --default-pip >/dev/null 2>&1 \
      && "$py" -m pip --version >/dev/null 2>&1; then
    echo "pip bootstrapped successfully."
    "$py" -m pip install --quiet --break-system-packages "$MEMPALACE_PACKAGE" \
      || die "pip install mempalace failed after bootstrap"
    verify_import "$py"
    return 0
  fi

  die "no package installer found (tried pip, uv, ensurepip). Install one of:
  pip:  https://pip.pypa.io/en/stable/installation/
  uv:   https://docs.astral.sh/uv/getting-started/installation/"
}

# Upgrade mempalace globally, trying pip → uv in order.
upgrade_mempalace() {
  local py="$1"
  local -x VIRTUAL_ENV="" CONDA_PREFIX=""
  if "$py" -m pip --version >/dev/null 2>&1; then
    "$py" -m pip install --quiet --break-system-packages --upgrade "$MEMPALACE_PACKAGE"
  elif command -v uv >/dev/null 2>&1; then
    uv pip install --system --python "$py" --upgrade "$MEMPALACE_PACKAGE"
  else
    die "no package installer available for upgrade"
  fi
}

verify_import() {
  local py="$1"
  check_mempalace_installed "$py" \
    || die "mempalace installed but cannot be imported — check your Python environment"
  echo "Installed mempalace $(get_mempalace_version "$py")"
}

# ─── Palace initialisation ──────────────────────────────────────────────────

init_palace() {
  local py="$1" project_root="$2" palace_path="$3"
  local gitignore="$project_root/.gitignore"

  # mempalace init respects .gitignore but has no --ignore-file flag.
  # Temporarily append editor/agent dirs so init skips them.
  local fence="# --- setup-memory: temporary ignores (safe to remove) ---"
  local tmp_ignores=".claude
.cursor
.agents"

  if [[ -f "$gitignore" ]]; then
    printf '\n%s\n%s\n%s\n' "$fence" "$tmp_ignores" "$fence" >>"$gitignore"
  else
    printf '%s\n%s\n%s\n' "$fence" "$tmp_ignores" "$fence" >"$gitignore"
  fi

  echo ""
  echo "Running mempalace init …"
  local init_rc=0
  MEMPALACE_PALACE_PATH="$palace_path" "$py" -m mempalace init "$project_root" \
    || init_rc=$?

  # Remove the temporary fence block from .gitignore
  sed -i '' "/$fence/,/$fence/d" "$gitignore"
  # Clean up trailing blank lines left behind
  sed -i '' -e :a -e '/^[[:space:]]*$/{' -e '$d' -e N -e ba -e '}' "$gitignore"

  [[ "$init_rc" -eq 0 ]] || die "mempalace init failed"
  echo ""
  echo "Palace initialised at $palace_path (project indexed)"
}

# ─── Cursor MCP ──────────────────────────────────────────────────────────────

merge_cursor_mcp_mempalace() {
  local path="$1" py="$2" palace_path="$3"
  local tmp
  tmp="$(mktemp)"
  mkdir -p "$(dirname "$path")"

  local jq_filter
  jq_filter='
    .mcpServers = (.mcpServers // {}) |
    .mcpServers.mempalace = {
      command: $py,
      args: ["-m", "mempalace.mcp_server", "--palace", $palace]
    }
  '

  if [[ -f "$path" ]]; then
    jq --arg py "$py" --arg palace "$palace_path" "$jq_filter" "$path" >"$tmp" \
      || die "jq failed on $path (invalid JSON?)"
  else
    jq -n --arg py "$py" --arg palace "$palace_path" "$jq_filter" >"$tmp"
  fi
  mv "$tmp" "$path"
  echo "Updated $path"
}

# ─── Cursor hooks ────────────────────────────────────────────────────────────

merge_cursor_hooks() {
  local hooks_path="$1" save_script="$2" precompact_script="$3"
  local tmp
  tmp="$(mktemp)"
  mkdir -p "$(dirname "$hooks_path")"

  if [[ -f "$hooks_path" ]]; then
    jq --arg save "$save_script" --arg precompact "$precompact_script" '
      .version = (.version // 1) |
      .hooks = (.hooks // {}) |

      # Replace any existing mempalace stop hook
      .hooks.stop = (
        [(.hooks.stop // [])[] | select(.command | contains("mempal_") | not)] +
        [{ command: $save }]
      ) |

      # Replace any existing mempalace preCompact hook
      .hooks.preCompact = (
        [(.hooks.preCompact // [])[] | select(.command | contains("mempal_") | not)] +
        [{ command: $precompact }]
      )
    ' "$hooks_path" >"$tmp" || die "jq failed on $hooks_path (invalid JSON?)"
  else
    jq -n --arg save "$save_script" --arg precompact "$precompact_script" '{
      version: 1,
      hooks: {
        stop: [{ command: $save }],
        preCompact: [{ command: $precompact }]
      }
    }' >"$tmp"
  fi
  mv "$tmp" "$hooks_path"
  echo "Updated $hooks_path"
}

# ─── Claude Code MCP ────────────────────────────────────────────────────────

setup_claude_mcp() {
  local py="$1" palace_path="$2" claude_mcp="$3"

  # Prefer the claude CLI if available
  if command -v claude >/dev/null 2>&1; then
    echo "Registering mempalace MCP server via claude CLI …"
    # Remove stale entry if present, ignore errors
    claude mcp remove mempalace --scope project 2>/dev/null || true
    claude mcp add --scope project mempalace -- \
      "$py" -m mempalace.mcp_server --palace "$palace_path" \
      || die "claude mcp add failed"
    echo "Registered mempalace MCP server (project scope)"
    return 0
  fi

  # Fallback: manual .mcp.json merge
  echo "claude CLI not found — falling back to manual .mcp.json merge."
  merge_claude_mcp_fallback "$claude_mcp" "$py" "$palace_path"
}

merge_claude_mcp_fallback() {
  local path="$1" py="$2" palace_path="$3"
  local tmp
  tmp="$(mktemp)"
  mkdir -p "$(dirname "$path")"

  local jq_filter='
    .mcpServers = (.mcpServers // {}) |
    .mcpServers.mempalace = {
      command: $py,
      args: ["-m", "mempalace.mcp_server", "--palace", $palace]
    }
  '

  if [[ -f "$path" ]]; then
    jq --arg py "$py" --arg palace "$palace_path" "$jq_filter" "$path" >"$tmp" \
      || die "jq failed on $path (invalid JSON?)"
  else
    jq -n --arg py "$py" --arg palace "$palace_path" "$jq_filter" >"$tmp"
  fi
  mv "$tmp" "$path"
  echo "Updated $path"
  echo "Restart Claude Code if it is running so MCP picks up changes."
}

# ─── Hook scripts ──────────────────────────────────────────────────────────

# Write the actual mempalace hook scripts to .mempalace/hooks/.
# These are the real hooks from the mempalace project — they read JSON from
# stdin, count transcript messages, and return block/allow decisions.
# See: https://github.com/milla-jovovich/mempalace/tree/main/hooks
write_hook_scripts() {
  local hooks_dir="$1/hooks"
  local save_interval="${2:-8}"
  mkdir -p "$hooks_dir"

  # ── Save hook ──────────────────────────────────────────────────────────
  cat >"$hooks_dir/mempal_save_hook.sh" <<'SAVEHOOK'
#!/bin/bash
# MEMPALACE SAVE HOOK — Auto-save every N exchanges
#
# Claude Code / Cursor "Stop" hook. After every assistant response:
# 1. Counts human messages in the session transcript
# 2. Every SAVE_INTERVAL messages, BLOCKS the AI from stopping
# 3. Returns a reason telling the AI to save structured entries
# 4. AI does the save (topics, decisions, code, quotes → organized into palace)
# 5. Next Stop fires with stop_hook_active=true → lets AI stop normally

SAVE_INTERVAL=__INTERVAL__  # Save every N human messages (adjust to taste)
STATE_DIR="$HOME/.mempalace/hook_state"
mkdir -p "$STATE_DIR"

# Read JSON input from stdin
INPUT=$(cat)

# Parse all fields in a single Python call
eval $(echo "$INPUT" | python3 -c "
import sys, json
data = json.load(sys.stdin)
sid = data.get('session_id', 'unknown')
sha = data.get('stop_hook_active', False)
tp = data.get('transcript_path', '')
import re
safe = lambda s: re.sub(r'[^a-zA-Z0-9_/.\-~]', '', str(s))
print(f'SESSION_ID=\"{safe(sid)}\"')
print(f'STOP_HOOK_ACTIVE=\"{sha}\"')
print(f'TRANSCRIPT_PATH=\"{safe(tp)}\"')
" 2>/dev/null)

# Expand ~ in path
TRANSCRIPT_PATH="${TRANSCRIPT_PATH/#\~/$HOME}"

# If we're already in a save cycle, let the AI stop normally
# This is the infinite-loop prevention: block once → AI saves → tries to stop again → we let it through
if [ "$STOP_HOOK_ACTIVE" = "True" ] || [ "$STOP_HOOK_ACTIVE" = "true" ]; then
    echo "{}"
    exit 0
fi

# Count human messages in the JSONL transcript
if [ -f "$TRANSCRIPT_PATH" ]; then
    EXCHANGE_COUNT=$(python3 - "$TRANSCRIPT_PATH" <<'PYEOF'
import json, sys
count = 0
with open(sys.argv[1]) as f:
    for line in f:
        try:
            entry = json.loads(line)
            msg = entry.get('message', {})
            if isinstance(msg, dict) and msg.get('role') == 'user':
                content = msg.get('content', '')
                if isinstance(content, str) and '<command-message>' in content:
                    continue
                count += 1
        except:
            pass
print(count)
PYEOF
2>/dev/null)
else
    EXCHANGE_COUNT=0
fi

# Track last save point for this session
LAST_SAVE_FILE="$STATE_DIR/${SESSION_ID}_last_save"
LAST_SAVE=0
if [ -f "$LAST_SAVE_FILE" ]; then
    LAST_SAVE=$(cat "$LAST_SAVE_FILE")
fi

SINCE_LAST=$((EXCHANGE_COUNT - LAST_SAVE))

# Log for debugging (check ~/.mempalace/hook_state/hook.log)
echo "[$(date '+%H:%M:%S')] Session $SESSION_ID: $EXCHANGE_COUNT exchanges, $SINCE_LAST since last save" >> "$STATE_DIR/hook.log"

# Time to save?
if [ "$SINCE_LAST" -ge "$SAVE_INTERVAL" ] && [ "$EXCHANGE_COUNT" -gt 0 ]; then
    echo "$EXCHANGE_COUNT" > "$LAST_SAVE_FILE"
    echo "[$(date '+%H:%M:%S')] TRIGGERING SAVE at exchange $EXCHANGE_COUNT" >> "$STATE_DIR/hook.log"

    cat << 'HOOKJSON'
{
  "decision": "block",
  "reason": "AUTO-SAVE checkpoint. Save key topics, decisions, quotes, and code from this session to your memory system. Organize into appropriate categories. Use verbatim quotes where possible. Continue conversation after saving."
}
HOOKJSON
else
    echo "{}"
fi
SAVEHOOK

  # ── PreCompact hook ────────────────────────────────────────────────────
  cat >"$hooks_dir/mempal_precompact_hook.sh" <<'PRECOMPACTHOOK'
#!/bin/bash
# MEMPALACE PRE-COMPACT HOOK — Emergency save before compaction
#
# Claude Code / Cursor "PreCompact" hook. Fires RIGHT BEFORE the conversation
# gets compressed to free up context window space.
#
# This ALWAYS blocks — compaction is always worth saving before.

STATE_DIR="$HOME/.mempalace/hook_state"
mkdir -p "$STATE_DIR"

INPUT=$(cat)

SESSION_ID=$(echo "$INPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('session_id','unknown'))" 2>/dev/null)

echo "[$(date '+%H:%M:%S')] PRE-COMPACT triggered for session $SESSION_ID" >> "$STATE_DIR/hook.log"

cat << 'HOOKJSON'
{
  "decision": "block",
  "reason": "COMPACTION IMMINENT. Save ALL topics, decisions, quotes, code, and important context from this session to your memory system. Be thorough — after compaction, detailed context will be lost. Organize into appropriate categories. Use verbatim quotes where possible. Save everything, then allow compaction to proceed."
}
HOOKJSON
PRECOMPACTHOOK

  # Inject the chosen save interval into the hook script
  sed -i '' "s/__INTERVAL__/${save_interval}/" "$hooks_dir/mempal_save_hook.sh"

  chmod +x "$hooks_dir/mempal_save_hook.sh" "$hooks_dir/mempal_precompact_hook.sh"
  echo "Wrote hook scripts to $hooks_dir/ (save interval: every ${save_interval} messages)"
}

# ─── Claude Code hooks ──────────────────────────────────────────────────────

merge_claude_hooks() {
  local settings_path="$1" save_script="$2" precompact_script="$3"
  local tmp
  tmp="$(mktemp)"
  mkdir -p "$(dirname "$settings_path")"

  if [[ -f "$settings_path" ]]; then
    jq --arg save "$save_script" --arg precompact "$precompact_script" '
      .hooks = (.hooks // {}) |

      # Replace any existing mempalace Stop hook (match by "mempal_")
      .hooks.Stop = (
        [(.hooks.Stop // [])[] | select((.hooks // []) | all(.command | contains("mempal_") | not))] +
        [{ matcher: "*", hooks: [{ type: "command", command: $save, timeout: 30 }] }]
      ) |

      # Replace any existing mempalace PreCompact hook
      .hooks.PreCompact = (
        [(.hooks.PreCompact // [])[] | select((.hooks // []) | all(.command | contains("mempal_") | not))] +
        [{ hooks: [{ type: "command", command: $precompact, timeout: 30 }] }]
      )
    ' "$settings_path" >"$tmp" || die "jq failed on $settings_path (invalid JSON?)"
  else
    jq -n --arg save "$save_script" --arg precompact "$precompact_script" '{
      hooks: {
        Stop: [{
          matcher: "*",
          hooks: [{ type: "command", command: $save, timeout: 30 }]
        }],
        PreCompact: [{
          hooks: [{ type: "command", command: $precompact, timeout: 30 }]
        }]
      }
    }' >"$tmp"
  fi
  mv "$tmp" "$settings_path"
  echo "Updated $settings_path"
}

# ─── Memory skill ────────────────────────────────────────────────────────────

# Install the `memory` skill into .agents/skills/memory/SKILL.md. This is the
# tool skill that teaches the agent how to use the mempalace MCP server and how
# to reason about persistent memory in general. Like the GitHub and Figma tool
# skills, it is opt-in: only present once memory has been configured for the
# project. init.sh copies .agents/skills/ into the editor skill directories.
write_memory_skill() {
  local skill_dir="$SKILLS_DIR/memory"
  mkdir -p "$skill_dir"

  cat >"$skill_dir/SKILL.md" <<'MEMORYSKILL'
---
name: memory
description: Persist and recall durable project knowledge across sessions using
  the mempalace memory palace. Recall relevant context before starting work;
  save decisions, rationale, conventions, and verbatim quotes after meaningful
  progress; mine the project into the palace. Use whenever the task benefits
  from remembering or retrieving context that outlives a single conversation.
category: tool
---

# Memory

Give the agent a memory that survives across sessions. This skill owns the
**mempalace** memory palace — a project-local, semantically searchable store of
durable knowledge — and explains how it relates to Claude's own built-in
memory. Setup is handled by `.agents/scripts/setup-memory.sh`; this skill is how
you actually use what that script installs.

## Mindset

- **Recall before you reinvent.** Before starting non-trivial work, search the
  palace for prior decisions, conventions, and context. Past-you already solved
  some of this — find it before guessing.
- **Save what won't be obvious later.** Persist decisions and their rationale,
  conventions, gotchas, domain facts, and the *why* behind non-obvious choices.
  Use verbatim quotes for anything where exact wording matters.
- **Don't hoard the derivable.** Skip what the code, git history, or README
  already make plain. Memory is for what an unfamiliar reader couldn't
  reconstruct from the repository alone.
- **One fact, well organized.** Save discrete, self-contained entries filed into
  sensible categories rather than dumping whole transcripts. A good entry is
  recallable on its own months later.
- **Memory is a draft, not gospel.** Recalled entries reflect what was true when
  written. Before acting on one that names a file, flag, or function, verify it
  still exists.

## When to recall

- At the start of a task that touches an area you (or a teammate) have worked in
  before — search the palace for the feature, module, or decision by name.
- When you hit a "why is it like this?" question — the rationale may be saved.
- When a convention or constraint isn't written in the code but feels assumed.

Search semantically (describe what you're looking for), not just by exact
keyword. If nothing relevant comes back, proceed and save what you learn.

## When to save

- After a meaningful decision: what was chosen, what was rejected, and why.
- After discovering a non-obvious constraint, gotcha, or domain fact.
- After agreeing on a convention that isn't enforced by tooling.
- When the user says "remember this," or gives durable guidance on how to work.
- The auto-save and pre-compact hooks will also prompt you to checkpoint — when
  they do, save the key topics, decisions, quotes, and code from the session,
  organized into appropriate categories, then continue.

### What to save

- **Decisions** — the choice, the alternatives, the rationale.
- **Conventions & constraints** — rules the code assumes but doesn't state.
- **Domain knowledge** — facts about the product, users, or environment.
- **Verbatim quotes** — exact wording from the user when precision matters.
- **Pointers** — links to tickets, dashboards, docs, or external resources.

Convert relative dates to absolute ones before saving. Link related entries so a
later recall surfaces the whole cluster.

## Mining

`setup-memory.sh mine` (or re-running setup and accepting the mine prompt) reads
the project's files into the palace, respecting `.mempalaceignore`. Run it after
large changes so semantic recall reflects the current codebase. Keep
`.mempalaceignore` honest — dependency trees, build output, and binaries don't
belong in the palace.

## Relationship to Claude's built-in memory

Claude Code also has a file-based memory directory of its own. Keep the two
distinct:

- **mempalace (this skill)** — *project* knowledge: decisions, conventions, and
  context about the codebase, shared with anyone working in the repo. Lives in
  the project-local palace.
- **Claude's own memory** — *cross-project* facts about the user and how they
  like to work: preferences, role, recurring feedback. Lives in Claude's memory
  directory, not the repo.

When a fact is about *this project*, it belongs in the palace. When it's about
*the user* or how you should work in general, it belongs in Claude's own memory.
Don't duplicate one into the other; link or reference instead.

## Composition

This skill is only useful once `setup-memory.sh` has registered the mempalace
MCP server and initialised a palace. If the palace isn't configured, there's no
project memory to read or write — fall back to gathering context from the code,
git history, and the conversation, and suggest running `setup-memory.sh` if
durable memory would help. Verify health any time with
`.agents/scripts/doctor.sh`.
MEMORYSKILL

  echo "Wrote $skill_dir/SKILL.md"
}

# Mirror a skill from .agents/skills/ into the editor-local skill dirs, the
# same way init.sh seeds them. Without this, Claude Code (.claude/skills/) and
# Cursor (.cursor/skills/) never see skills that setup-memory installs.
sync_skill_to_editors() {
  local project_root="$1" skill="$2"
  local src="$SKILLS_DIR/$skill"
  [[ -d "$src" ]] || return 0
  local dest
  for dest in "$project_root/.claude/skills" "$project_root/.cursor/skills"; do
    mkdir -p "$dest"
    rm -rf "${dest:?}/$skill"
    cp -R "$src" "$dest/$skill"
    echo "  skills/$skill → ${dest#$project_root/}/$skill"
  done
}

# Install the memory rule — an always-on guide for HOW AGGRESSIVELY to use
# memory (recall before acting, save what won't be obvious, verify recalls).
# Sourced from .agents/tools/ and copied into the editor rule dirs. Opt-in:
# installed here by setup-memory (when memory is configured), NOT by init.sh —
# so projects without memory don't carry a rule for a system they lack.
#   .md  → .claude/rules/   (Claude Code)
#   .mdc → .cursor/rules/   (Cursor; has rule frontmatter)
install_memory_rule() {
  local project_root="$1"
  local src_md="$AGENTS_ROOT/tools/memory.md"
  local src_mdc="$AGENTS_ROOT/tools/memory.mdc"
  if [[ -f "$src_md" ]]; then
    mkdir -p "$project_root/.claude/rules"
    cp "$src_md" "$project_root/.claude/rules/memory.md"
    echo "  tools/memory.md  → .claude/rules/memory.md"
  fi
  if [[ -f "$src_mdc" ]]; then
    mkdir -p "$project_root/.cursor/rules"
    cp "$src_mdc" "$project_root/.cursor/rules/memory.mdc"
    echo "  tools/memory.mdc → .cursor/rules/memory.mdc"
  fi
}

# ─── Ignore file ─────────────────────────────────────────────────────────────

# Default ignore patterns — keeps dependency trees, build artefacts, and binary
# blobs out of the palace. One pattern per line, gitignore-style.
IGNORE_PATTERNS='# Dependencies
node_modules/
vendor/
bower_components/
.pnp/
.yarn/

# Build output
dist/
build/
out/
.next/
.nuxt/
.output/
.svelte-kit/
.turbo/
target/

# Python
__pycache__/
*.pyc
.venv/
venv/
env/
.eggs/
*.egg-info/

# Package manager caches
.npm/
.pnpm-store/
.cache/

# IDE / editor
.idea/
.cursor/
.vscode/
*.swp
*.swo

# AI tooling
.claude/
.agents/

# Version control
.git/

# OS
.DS_Store
Thumbs.db

# Large / binary
*.zip
*.tar.gz
*.tgz
*.jar
*.war
*.so
*.dylib
*.dll
*.wasm
*.sqlite
*.sqlite3
*.db

# Misc generated
coverage/
.nyc_output/
.pytest_cache/
.mypy_cache/
.ruff_cache/
htmlcov/
*.log
'

write_mempalaceignore() {
  local project_root="$1"
  local ignore_file="$project_root/.mempalaceignore"
  printf '%s' "$IGNORE_PATTERNS" >"$ignore_file"

  echo ""
  echo "Default ignore patterns have been written to .mempalaceignore."
  echo "You can add extra folders or files to ignore (comma-separated)."
  echo "  Examples: logs/,tmp/,*.csv,data/"
  echo ""
  read -r -p "Additional ignores (or press Enter to skip): " extra_ignores
  if [[ -n "$extra_ignores" ]]; then
    printf '\n# Custom ignores\n' >>"$ignore_file"
    # Split on comma, trim whitespace, write one pattern per line
    local IFS=','
    for entry in $extra_ignores; do
      # Trim leading/trailing whitespace
      entry="${entry#"${entry%%[![:space:]]*}"}"
      entry="${entry%"${entry##*[![:space:]]}"}"
      [[ -n "$entry" ]] && printf '%s\n' "$entry" >>"$ignore_file"
    done
  fi

  echo "Wrote $ignore_file"
}

# ─── Palace git hygiene ───────────────────────────────────────────────────────

# Configure the project's .gitignore so the palace is portable AND drift-proof:
#   COMMIT (ground truth):  chroma.sqlite3, knowledge_graph.sqlite3, hooks/
#   IGNORE (derived/local): the <uuid>/ HNSW vector index, quarantine backups,
#                           rebuild archives, sqlite WAL/SHM journals
# The vector index is machine-specific and drift-prone; it is rebuilt locally
# from sqlite (see ensure_index). Committing it bloats git and — because its
# dir names change on every rebuild — guarantees a stale-index mismatch on
# checkout (the #1 silent corruption source). Idempotent: rewrites a fenced
# managed block and untracks anything that is now ignored but still tracked.
manage_palace_gitignore() {
  local project_root="$1"
  local gi="$project_root/.gitignore"
  local start="# --- mempalace palace (managed by setup-memory) ---"
  local end="# --- end mempalace palace ---"

  [[ -f "$gi" ]] && sed -i '' "/$start/,/$end/d" "$gi"
  sed -i '' -e :a -e '/^[[:space:]]*$/{' -e '$d' -e N -e ba -e '}' "$gi" 2>/dev/null || true

  cat >>"$gi" <<EOF

$start
# Commit the DATA (ground truth): chroma.sqlite3 + knowledge_graph.sqlite3.
# Ignore the DERIVED, machine-specific vector index and transient artefacts —
# rebuilt locally from sqlite by 'setup-memory.sh repair'.
.mempalace/*-*-*-*-*/
.mempalace/*.corrupt-*
.mempalace/*.drift-*
.mempalace.pre-rebuild-*
.mempalace/*.sqlite3-wal
.mempalace/*.sqlite3-shm
$end
EOF
  echo "Updated $gi (commit sqlite; ignore derived index + backups)"

  # Untrack anything under .mempalace that is now ignored but still tracked —
  # e.g. a previously-committed vector index, which is a stale-checkout landmine.
  if git -C "$project_root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    local untracked=0 f
    while IFS= read -r f; do
      [[ -z "$f" ]] && continue
      case "$f" in
        .mempalace/chroma.sqlite3 | .mempalace/knowledge_graph.sqlite3 | \
          .mempalace/.blob_seq_ids_migrated | .mempalace/hooks/* | .mempalace/.mempalace/*)
          : ;; # keep tracked: data + hooks + origin
        *)
          git -C "$project_root" rm --cached --quiet -- "$f" && untracked=$((untracked + 1)) ;;
      esac
    done < <(git -C "$project_root" ls-files -- .mempalace)
    [[ "$untracked" -gt 0 ]] \
      && echo "  Untracked $untracked stale palace index/backup file(s) from git"
  fi
}

# ─── Vector index rebuild (portability / drift recovery) ──────────────────────

# Rebuild the HNSW vector index from chroma.sqlite3 when it's missing — e.g.
# after checking the repo out on a new machine (we commit sqlite but gitignore
# the index), or after concurrent-writer drift quarantined it. sqlite is the
# ground truth, so this is lossless. Idempotent: a no-op when a live index
# already exists, unless called with "force".
ensure_index() {
  local py="$1" project_root="$2" palace_path="$3" force="${4:-}"
  if [[ ! -f "$palace_path/chroma.sqlite3" ]]; then
    [[ "$force" == "force" ]] && echo "No chroma.sqlite3 at $palace_path — nothing to rebuild."
    return 0
  fi

  if [[ "$force" != "force" ]]; then
    # A live index = at least one uuid-named collection dir that isn't a backup.
    if find "$palace_path" -mindepth 1 -maxdepth 1 -type d \
         -name '*-*-*-*-*' ! -name '*.corrupt-*' ! -name '*.drift-*' 2>/dev/null \
         | grep -q .; then
      return 0
    fi
    echo ""
    echo "Palace has data (chroma.sqlite3) but no vector index — rebuilding from"
    echo "sqlite (e.g. fresh checkout). Lossless; sqlite is the source of truth."
  else
    echo ""
    echo "Rebuilding vector index from chroma.sqlite3 (forced) …"
  fi

  MEMPALACE_PALACE_PATH="$palace_path" \
    "$py" -m mempalace repair --mode from-sqlite --archive-existing --yes \
    || { echo "warning: index rebuild returned non-zero"; return 0; }
  # The rebuilt palace's sqlite is complete; drop the archive copy it leaves behind.
  rm -rf "${palace_path}".pre-rebuild-* 2>/dev/null || true
  echo "Vector index rebuilt from sqlite."
}

# ─── Project mining ──────────────────────────────────────────────────────────

# Build an array of find-exclude arguments from the ignore file.
# Reads .mempalaceignore (gitignore-style), strips comments and blanks,
# and converts directory patterns (foo/) into -not -path '*/foo/*'.
build_find_excludes() {
  local ignore_file="$1"
  [[ -f "$ignore_file" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    # Strip comments and whitespace-only lines
    line="${line%%#*}"
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [[ -z "$line" ]] && continue
    # Directory pattern (trailing /) — one argument per line so the
    # caller's read loop captures each as a separate array element.
    if [[ "$line" == */ ]]; then
      local dir="${line%/}"
      printf '%s\n' "-not"
      printf '%s\n' "-path"
      printf '%s\n' "*/${dir}/*"
    else
      # File glob pattern
      printf '%s\n' "-not"
      printf '%s\n' "-name"
      printf '%s\n' "$line"
    fi
  done <"$ignore_file"
}

# Map a project root to its Claude Code transcript directory.
# Claude Code stores per-project transcripts under ~/.claude/projects/<encoded>,
# where <encoded> is the absolute project path with every non-alphanumeric
# character replaced by '-'. e.g. /Users/me/work/app -> -Users-me-work-app.
claude_transcript_dir() {
  local project_root="$1" encoded
  encoded="$(printf '%s' "$project_root" | sed 's/[^a-zA-Z0-9]/-/g')"
  printf '%s/.claude/projects/%s' "$HOME" "$encoded"
}

# Backfill THIS project's past Claude Code conversations into the palace.
#
# Distinct from mine_project (code/docs): this ingests chat history via
# `--mode convos`, so decisions made in sessions that predate the auto-save
# hooks are still recoverable. The hooks only capture conversations going
# forward — this is the one-time catch-up.
#
# Scoped to the project's OWN transcript dir, never the bare ~/.claude/projects/
# (that holds every project on the machine and would pollute this wing). We also
# pin --wing to the project's basename; otherwise mempalace defaults the wing to
# the long encoded directory name rather than the project name.
mine_convos() {
  local py="$1" project_root="$2" palace_path="$3"
  local convo_dir wing
  convo_dir="$(claude_transcript_dir "$project_root")"
  wing="$(basename "$project_root")"

  if [[ ! -d "$convo_dir" ]]; then
    echo "No Claude Code transcripts found for this project at:"
    echo "  $convo_dir"
    echo "Skipping conversation backfill (nothing to mine yet)."
    return 0
  fi

  # Claude Code keeps the actual chat logs as <session-id>.jsonl at the TOP
  # LEVEL of the transcript dir. The subdirectories hold derived artefacts —
  # tool-result dumps (*.txt) and subagent transcripts — which are not
  # conversation and pollute the palace (a tool-result dump is often just a
  # copy of a file we already mine as code). `mempalace mine` recurses a
  # directory and offers no exclude flag, and it won't accept a single file
  # (it scans its argument as a dir), so we stage only the top-level chat logs
  # into a temp dir and mine that.
  local staging n=0 f
  staging="$(mktemp -d)"
  for f in "$convo_dir"/*.jsonl; do
    [[ -e "$f" ]] || continue
    cp "$f" "$staging/"
    n=$((n + 1))
  done

  if [[ "$n" -eq 0 ]]; then
    rm -rf "$staging"
    echo "No Claude Code chat logs (*.jsonl) found in $convo_dir — skipping backfill."
    return 0
  fi

  echo ""
  echo "Backfilling Claude Code conversation history into wing '$wing' …"
  echo "  Source: $convo_dir"
  echo "  Mining $n chat log(s) (tool-result dumps and subagent transcripts excluded)"

  MEMPALACE_PALACE_PATH="$palace_path" \
    "$py" -m mempalace mine "$staging" --mode convos --wing "$wing" \
    || echo "warning: conversation mine returned non-zero (may be non-fatal)"
  rm -rf "$staging"
  echo "Conversation backfill complete."
}

# Run both mine modes against the project: files (projects) + Claude Code
# transcripts (convos). The single entry point for a full refresh.
mine_all() {
  local py="$1" project_root="$2" palace_path="$3"
  mine_project "$py" "$project_root" "$palace_path"
  mine_convos "$py" "$project_root" "$palace_path"
}

mine_project() {
  local py="$1" project_root="$2" palace_path="$3"
  local ignore_file="$project_root/.mempalaceignore"

  echo ""
  echo "Mining project files …"

  # Try native --ignore-file flag first
  if MEMPALACE_PALACE_PATH="$palace_path" \
     "$py" -m mempalace mine --ignore-file "$ignore_file" "$project_root" 2>/dev/null; then
    echo "Mining complete."
    return 0
  fi

  # Fallback: use find to pre-filter, pipe file list to mempalace mine --stdin
  echo "Retrying with filtered file list (applying .mempalaceignore) …"
  local -a excludes=()
  while IFS= read -r arg || [[ -n "$arg" ]]; do
    excludes+=("$arg")
  done < <(build_find_excludes "$ignore_file")

  if MEMPALACE_PALACE_PATH="$palace_path" \
     find "$project_root" -type f "${excludes[@]}" -print0 \
     | "$py" -m mempalace mine --stdin --palace "$palace_path" 2>/dev/null; then
    echo "Mining complete."
    return 0
  fi

  # Last resort: plain mine (no ignore support)
  echo "Retrying plain mine (ignore patterns may not be applied) …"
  MEMPALACE_PALACE_PATH="$palace_path" "$py" -m mempalace mine "$project_root" \
    || echo "warning: mempalace mine returned non-zero (may be non-fatal)"
  echo "Mining complete."
}

# ─── Uninstall ────────────────────────────────────────────────────────────────

# Remove the mempalace MCP server registration from both editors. Mirrors
# setup_claude_mcp / merge_cursor_mcp_mempalace: deregister via the claude CLI
# when present, and strip the .mcpServers.mempalace key from both JSON configs.
remove_mcp() {
  local project_root="$1" claude_mcp="$2" cursor_mcp="$3"

  if command -v claude >/dev/null 2>&1; then
    claude mcp remove mempalace --scope project >/dev/null 2>&1 \
      && echo "  removed mempalace MCP via claude CLI (project scope)" || true
  fi

  local f tmp
  for f in "$claude_mcp" "$cursor_mcp"; do
    [[ -f "$f" ]] || continue
    jq -e '.mcpServers.mempalace' "$f" >/dev/null 2>&1 || continue
    tmp="$(mktemp)"
    if jq 'del(.mcpServers.mempalace)' "$f" >"$tmp" 2>/dev/null; then
      mv "$tmp" "$f"
      echo "  removed mcpServers.mempalace from $f"
    else
      rm -f "$tmp"
      echo "  ⚠ jq failed on $f — left unchanged"
    fi
  done
}

# Strip the mempalace hooks (matched by "mempal_") from both editors' hook
# configs. Reverses merge_claude_hooks (.hooks.Stop/.PreCompact in
# settings.local.json) and merge_cursor_hooks (.hooks.stop/.preCompact).
remove_hooks() {
  local claude_settings="$1" cursor_hooks="$2"
  local tmp

  if [[ -f "$claude_settings" ]]; then
    tmp="$(mktemp)"
    if jq '
      if .hooks then
        .hooks.Stop = [ (.hooks.Stop // [])[]
          | select((.hooks // []) | all(.command | contains("mempal_") | not)) ] |
        .hooks.PreCompact = [ (.hooks.PreCompact // [])[]
          | select((.hooks // []) | all(.command | contains("mempal_") | not)) ] |
        if (.hooks.Stop | length) == 0 then del(.hooks.Stop) else . end |
        if (.hooks.PreCompact | length) == 0 then del(.hooks.PreCompact) else . end |
        if (.hooks | length) == 0 then del(.hooks) else . end
      else . end
    ' "$claude_settings" >"$tmp" 2>/dev/null; then
      mv "$tmp" "$claude_settings"
      echo "  removed mempalace hooks from $claude_settings"
    else
      rm -f "$tmp"
      echo "  ⚠ jq failed on $claude_settings — left unchanged"
    fi
  fi

  if [[ -f "$cursor_hooks" ]]; then
    tmp="$(mktemp)"
    if jq '
      if .hooks then
        .hooks.stop = [ (.hooks.stop // [])[] | select(.command | contains("mempal_") | not) ] |
        .hooks.preCompact = [ (.hooks.preCompact // [])[] | select(.command | contains("mempal_") | not) ] |
        if (.hooks.stop | length) == 0 then del(.hooks.stop) else . end |
        if (.hooks.preCompact | length) == 0 then del(.hooks.preCompact) else . end
      else . end
    ' "$cursor_hooks" >"$tmp" 2>/dev/null; then
      mv "$tmp" "$cursor_hooks"
      echo "  removed mempalace hooks from $cursor_hooks"
    else
      rm -f "$tmp"
      echo "  ⚠ jq failed on $cursor_hooks — left unchanged"
    fi
  fi
}

# Remove the memory skill (source + editor mirrors) and the memory rule.
# Reverses write_memory_skill / sync_skill_to_editors / install_memory_rule.
remove_skill_and_rule() {
  local project_root="$1"
  rm -rf "$SKILLS_DIR/memory"
  echo "  removed $SKILLS_DIR/memory"
  local dest
  for dest in "$project_root/.claude/skills/memory" "$project_root/.cursor/skills/memory"; do
    rm -rf "$dest"
    echo "  removed ${dest#$project_root/}"
  done
  # Clear the memory rule from both editor dirs, both extensions. Install only
  # writes memory.md → .claude and memory.mdc → .cursor, but past setups may
  # have cross-placed them, so remove every memory.{md,mdc} defensively.
  rm -f "$project_root/.claude/rules/memory.md"  "$project_root/.claude/rules/memory.mdc" \
        "$project_root/.cursor/rules/memory.md"  "$project_root/.cursor/rules/memory.mdc"
  echo "  removed memory rule (memory.{md,mdc}) from .claude/rules/ and .cursor/rules/"
  manifest_remove "memory"
}

# Remove the fenced palace block that manage_palace_gitignore wrote.
remove_palace_gitignore() {
  local project_root="$1"
  local gi="$project_root/.gitignore"
  [[ -f "$gi" ]] || return 0
  local start="# --- mempalace palace (managed by setup-memory) ---"
  local end="# --- end mempalace palace ---"
  if grep -qF "$start" "$gi"; then
    sed -i '' "/$start/,/$end/d" "$gi"
    # Clean up trailing blank lines left behind.
    sed -i '' -e :a -e '/^[[:space:]]*$/{' -e '$d' -e N -e ba -e '}' "$gi" 2>/dev/null || true
    echo "  removed mempalace block from $gi"
  fi
}

uninstall() {
  local project_root
  project_root="$(pwd -P)"
  local palace_path="$project_root/.mempalace"
  local cursor_mcp="$project_root/.cursor/mcp.json"
  local cursor_hooks="$project_root/.cursor/hooks.json"
  local claude_mcp="$project_root/.mcp.json"
  local claude_settings_local="$project_root/.claude/settings.local.json"
  local ignore_file="$project_root/.mempalaceignore"

  require_cmd jq

  local bar
  bar="$(printf '%*s' 68 '' | tr ' ' '=')"
  echo "$bar"
  echo "  $PROG_NAME · Uninstall  v$TOOL_VERSION"
  echo ""
  echo "  Deregisters the mempalace MCP server and hooks, removes the memory"
  echo "  skill + rule, drops the .gitignore block, and re-enables Claude"
  echo "  Code's built-in auto-memory. The globally-installed mempalace"
  echo "  package is left in place (it is shared across projects)."
  echo ""
  printf '  %-16s %s\n' "Project Root" "$project_root"
  echo "$bar"
  echo ""

  echo "── Removing MCP registration ──"
  remove_mcp "$project_root" "$claude_mcp" "$cursor_mcp"
  echo ""

  echo "── Removing hooks ──"
  remove_hooks "$claude_settings_local" "$cursor_hooks"
  echo ""

  echo "── Removing memory skill + rule ──"
  remove_skill_and_rule "$project_root"
  echo ""

  echo "── Restoring .gitignore ──"
  remove_palace_gitignore "$project_root"
  echo ""

  echo "── Re-enabling Claude Code auto-memory ──"
  set_auto_memory "$project_root" true
  echo ""

  # Ignore file is a memory artefact — safe to drop on uninstall.
  if [[ -f "$ignore_file" ]]; then
    rm -f "$ignore_file"
    echo "Removed $ignore_file"
    echo ""
  fi

  # Palace DATA is the one destructive choice: chroma.sqlite3 holds saved
  # memories and is committed to git. Preserve by default; delete only on
  # explicit confirmation.
  if [[ -d "$palace_path" ]]; then
    echo "The palace directory still holds your saved memories:"
    echo "  $palace_path"
    echo "  (chroma.sqlite3 is committed to git — deleting loses that history)"
    echo ""
    read -r -p "Delete the .mempalace palace data too? [y/N] " do_del
    if [[ "${do_del:-n}" =~ ^[Yy] ]]; then
      rm -rf "$palace_path"
      echo "Removed $palace_path"
    else
      echo "Kept $palace_path (run 'rm -rf .mempalace' yourself to remove it later)."
    fi
    echo ""
  fi

  echo "$bar"
  echo "  Done. mempalace deregistered; auto-memory re-enabled."
  echo "  The mempalace package is still installed globally — remove it with:"
  echo "    python3 -m pip uninstall mempalace"
  echo "  Restart your editor so it drops the (now-removed) MCP server + hooks."
  echo "$bar"
}

# ─── Main ────────────────────────────────────────────────────────────────────

# Check whether all setup artefacts are already in place.
# Returns 0 (true) only if every piece is present.
is_fully_setup() {
  local py="$1" palace_path="$2" cursor_mcp="$3" cursor_hooks="$4"
  local claude_mcp="$5" claude_settings="$6" ignore_file="$7"

  # mempalace importable
  check_mempalace_installed "$py" || return 1
  # Palace directory
  [[ -d "$palace_path" ]] || return 1
  # Hook scripts
  [[ -x "$palace_path/hooks/mempal_save_hook.sh" ]] || return 1
  [[ -x "$palace_path/hooks/mempal_precompact_hook.sh" ]] || return 1
  # Memory skill
  [[ -f "$SKILLS_DIR/memory/SKILL.md" ]] || return 1
  # Ignore file
  [[ -f "$ignore_file" ]] || return 1
  # Cursor MCP entry
  [[ -f "$cursor_mcp" ]] \
    && jq -e '.mcpServers.mempalace' "$cursor_mcp" >/dev/null 2>&1 || return 1
  # Cursor hooks
  [[ -f "$cursor_hooks" ]] \
    && jq -e '.hooks.stop' "$cursor_hooks" >/dev/null 2>&1 || return 1
  # Claude MCP (via .mcp.json or claude CLI)
  local claude_ok=false
  if [[ -f "$claude_mcp" ]] \
      && jq -e '.mcpServers.mempalace' "$claude_mcp" >/dev/null 2>&1; then
    claude_ok=true
  elif command -v claude >/dev/null 2>&1 \
      && claude mcp list --scope project 2>/dev/null | grep -qi mempalace; then
    claude_ok=true
  fi
  [[ "$claude_ok" == "true" ]] || return 1
  # Claude hooks
  [[ -f "$claude_settings" ]] \
    && jq -e '.hooks.Stop' "$claude_settings" >/dev/null 2>&1 || return 1

  return 0
}

# Verify that the project has been fully set up (mempalace installed + palace initialised).
require_setup() {
  local py="$1" palace_path="$2"
  check_mempalace_installed "$py" \
    || die "mempalace is not installed — run this script without arguments first"
  [[ -d "$palace_path" ]] \
    || die "palace not initialised at $palace_path — run this script without arguments first"
}

main() {
  case "${1:-}" in
    -h | --help | help)
      echo "$PROG_NAME · Byrde Agents v$TOOL_VERSION"
      echo ""
      echo "Usage:"
      echo "  cd /your/project && $0                 # full setup"
      echo "  cd /your/project && $0 mine            # mine both files + chat history (setup first)"
      echo "  cd /your/project && $0 mine projects   # mine project files only"
      echo "  cd /your/project && $0 mine convos     # backfill Claude Code chat history only"
      echo "  cd /your/project && $0 repair          # rebuild vector index from chroma.sqlite3"
      echo "  cd /your/project && $0 uninstall       # deregister MCP/hooks, re-enable auto-memory"
      echo ""
      echo "Full setup installs mempalace (if needed) and configures:"
      echo "  .mempalace/                     — project-local palace data"
      echo "  .mempalace/hooks/               — save and precompact hook scripts"
      echo "  .mempalaceignore                — ignore patterns for mining"
      echo "  .gitignore                      — commit sqlite; ignore the derived index"
      echo "  .agents/skills/memory/SKILL.md  — skill for using memory"
      echo "  .claude|.cursor/rules/memory.*  — rule: how aggressively to use memory"
      echo "  MCP + hooks                     — for the ONE editor you choose"
      exit 0
      ;;
    mine)
      shift
      local py
      py="$(resolve_python)"
      local project_root
      project_root="$(pwd -P)"
      local palace_path="$project_root/.mempalace"

      require_setup "$py" "$palace_path"
      case "${1:-all}" in
        projects) mine_project "$py" "$project_root" "$palace_path" ;;
        convos)   mine_convos  "$py" "$project_root" "$palace_path" ;;
        all)      mine_all     "$py" "$project_root" "$palace_path" ;;
        *) die "unknown mine target '${1}' (use: projects | convos | all)" ;;
      esac
      exit 0
      ;;
    repair | rebuild-index)
      # Force-rebuild the vector index from chroma.sqlite3 (the ground truth).
      # Use after a fresh checkout, or if search behaves oddly / drift is suspected.
      local py
      py="$(resolve_python)"
      local project_root
      project_root="$(pwd -P)"
      local palace_path="$project_root/.mempalace"

      require_setup "$py" "$palace_path"
      ensure_index "$py" "$project_root" "$palace_path" force
      exit 0
      ;;
    uninstall | remove)
      uninstall
      exit 0
      ;;
  esac

  require_cmd jq

  local py
  py="$(resolve_python)"

  local project_root
  project_root="$(pwd -P)"
  local palace_path="$project_root/.mempalace"
  local cursor_mcp="$project_root/.cursor/mcp.json"
  local cursor_hooks="$project_root/.cursor/hooks.json"
  local claude_mcp="$project_root/.mcp.json"
  local claude_settings="$project_root/.claude/settings.local.json"
  local ignore_file="$project_root/.mempalaceignore"

  print_intro "$project_root"

  # ── Pre-flight: detect existing setup ─────────────────────────────────────

  if is_fully_setup "$py" "$palace_path" "$cursor_mcp" "$cursor_hooks" \
                    "$claude_mcp" "$claude_settings" "$ignore_file"; then
    local ver
    ver="$(get_mempalace_version "$py")"
    echo "mempalace $ver is already fully configured for this project."
    echo ""
    echo "  Palace:         $palace_path"
    echo "  Hook scripts:   $palace_path/hooks/"
    echo "  Memory skill:   $SKILLS_DIR/memory/SKILL.md"
    echo "  Cursor MCP:     $cursor_mcp"
    echo "  Cursor hooks:   $cursor_hooks"
    echo "  Claude MCP:     configured"
    echo "  Claude hooks:   $claude_settings"
    echo "  Ignore file:    $ignore_file"
    echo ""
    read -r -p "Re-run setup? [y/N] " do_rerun
    if [[ ! "${do_rerun:-n}" =~ ^[Yy] ]]; then
      echo "Nothing to do."
      exit 0
    fi
    echo ""
  fi

  # ── Step 1: Ensure mempalace is installed ─────────────────────────────────

  if check_mempalace_installed "$py"; then
    local ver
    ver="$(get_mempalace_version "$py")"
    echo "mempalace $ver is already installed."
    echo ""
    read -r -p "Upgrade to latest? [y/N] " do_upgrade
    if [[ "${do_upgrade:-n}" =~ ^[Yy] ]]; then
      echo "Upgrading mempalace …"
      upgrade_mempalace "$py"
      echo "Upgraded to $(get_mempalace_version "$py")"
    fi
  else
    echo "mempalace is not installed."
    echo ""
    install_mempalace "$py"
  fi

  # ── Step 2: Write .mempalaceignore ─────────────────────────────────────────

  echo ""
  read -r -p "Configure .mempalaceignore? [Y/n] " a_ignore
  if [[ "${a_ignore:-y}" =~ ^[Yy] ]]; then
    write_mempalaceignore "$project_root"
  else
    echo "Skipping .mempalaceignore."
  fi

  # Palace git hygiene: commit sqlite (the portable ground truth), ignore the
  # derived/machine-specific vector index + backups, and untrack any stale index
  # already committed. Always run — this is what makes the palace safe to commit.
  echo ""
  manage_palace_gitignore "$project_root"

  # ── Step 3: Initialise the palace, then mine both sources ─────────────────
  #
  # Two mine modes, both run here:
  #   projects — the project's own files/docs (semantic recall of the codebase)
  #   convos   — this project's past Claude Code transcripts (one-time catch-up;
  #              the auto-save hooks only capture sessions going forward)
  #
  # A fresh `mempalace init` already indexes project files, so on first-time
  # init we only need the convos backfill on top. For an already-initialised
  # palace we offer a refresh that re-mines both.

  if [[ -d "$palace_path" && -f "$palace_path/chroma.sqlite3" ]]; then
    echo ""
    echo "Palace already initialised at $palace_path"
    read -r -p "Re-mine this project (files + conversation history) into the palace now? [Y/n] " do_remine
    if [[ "${do_remine:-y}" =~ ^[Yy] ]]; then
      mine_all "$py" "$project_root" "$palace_path"
    fi
  else
    init_palace "$py" "$project_root" "$palace_path"
    mine_convos "$py" "$project_root" "$palace_path"
  fi

  # Ensure a usable vector index exists. init/mine above normally build it; this
  # also covers the commit-sqlite / gitignore-index portability path — on a
  # fresh checkout sqlite is present but the index isn't, so rebuild from sqlite.
  ensure_index "$py" "$project_root" "$palace_path"

  # ── Step 4: Write hook scripts + register hooks ───────────────────────────

  echo ""
  read -r -p "Write hook scripts (save + precompact)? [Y/n] " a_hooks
  local save_script="$palace_path/hooks/mempal_save_hook.sh"
  local precompact_script="$palace_path/hooks/mempal_precompact_hook.sh"
  if [[ "${a_hooks:-y}" =~ ^[Yy] ]]; then
    echo ""
    read -r -p "Auto-save interval (number of user messages between saves) [8]: " save_interval
    save_interval="${save_interval:-8}"
    # Validate: must be a positive integer
    if ! [[ "$save_interval" =~ ^[1-9][0-9]*$ ]]; then
      echo "Invalid interval '$save_interval' — using default of 8."
      save_interval=8
    fi
    write_hook_scripts "$palace_path" "$save_interval"

    echo ""
    echo "── Registering hooks ──"
    merge_cursor_hooks "$cursor_hooks" "$save_script" "$precompact_script"
    merge_claude_hooks "$claude_settings" "$save_script" "$precompact_script"
  else
    echo "Skipping hook scripts."
  fi

  # ── Step 5: MCP servers (always configured — mempalace needs them) ───────

  echo ""
  echo "── Configuring MCP servers ──"
  merge_cursor_mcp_mempalace "$cursor_mcp" "$py" "$palace_path"
  setup_claude_mcp "$py" "$palace_path" "$claude_mcp"

  # ── Step 6: Install the memory skill + rule ──────────────────────────────

  echo ""
  echo "── Installing memory skill + rule ──"
  # In multi-repo mode, keep the per-repo .byrde/ staging out of git.
  ignore_skills_home
  write_memory_skill
  # SKILLS_DIR is the source of truth; mirror into the editor skill dirs
  # so Claude Code and Cursor pick it up without re-running init.sh.
  sync_skill_to_editors "$project_root" "memory"
  manifest_add "memory"
  # Always-on rule for how aggressively to use memory (from .agents/tools/).
  install_memory_rule "$project_root"

  # ── Step 7: Disable Claude Code's built-in auto-memory ────────────────────
  # mempalace is now the project's memory system; running Claude Code's native
  # auto-memory alongside it duplicates effort and splits knowledge across two
  # stores. Turn it off here; `uninstall` turns it back on.

  echo ""
  echo "── Disabling Claude Code auto-memory (mempalace replaces it) ──"
  set_auto_memory "$project_root" false

  # ── Done ──────────────────────────────────────────────────────────────────

  echo ""
  local bar
  bar="$(printf '%*s' 68 '' | tr ' ' '=')"
  echo "$bar"
  echo "  Done."
  echo ""
  echo "  Palace:   $palace_path"
  echo "  Python:   $py"
  echo "  Version:  $(get_mempalace_version "$py")"
  echo "  Skill:    $SKILLS_DIR/memory/SKILL.md"
  echo "            → .claude/skills/memory and .cursor/skills/memory"
  echo ""
  echo "  Memory MCP registered in:"
  if command -v claude >/dev/null 2>&1; then
    echo "    Claude Code — MCP via claude CLI (project scope); hooks: $claude_settings"
  else
    echo "    Claude Code — MCP: $claude_mcp; hooks: $claude_settings"
  fi
  echo "    Cursor — MCP: $cursor_mcp; hooks: $cursor_hooks"
  echo ""
  echo "  Git: chroma.sqlite3 is committed (portable data); the vector index is"
  echo "       gitignored and rebuilt locally — run '$0 repair' after a checkout."
  echo ""
  echo "  Claude Code auto-memory is now OFF (mempalace replaces it)."
  echo "  Undo everything with: $0 uninstall"
  echo ""
  echo "  Next steps:"
  echo "    1. Restart your editor to load the MCP server."
  echo "    2. Verify mempalace tools are available."
  echo "    3. Re-mine after changes:    $0 mine     (files + chat)"
  echo "    4. Rebuild index on checkout: $0 repair"
  echo "$bar"
}

main "$@"
