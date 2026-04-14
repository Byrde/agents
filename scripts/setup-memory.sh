#!/usr/bin/env bash
# Configure mempalace memory system for both Claude Code and Cursor.
#
# Installs mempalace (if not present), initialises a project-local palace,
# registers the MCP server for both editors, and sets up auto-save hooks.
#
# Run from the repository/project root you want to configure (current working directory).
# Writes:
#   - .mempalace/                     — project-local palace data
#   - .mempalace/hooks/               — save and precompact hook scripts
#   - .mempalaceignore                — ignore patterns for mining (node_modules, etc.)
#   - .cursor/mcp.json                — Cursor project MCP (mempalace server merged in)
#   - .cursor/hooks.json              — Cursor hooks (stop + preCompact)
#   - .mcp.json                       — Claude Code project MCP (fallback if CLI unavailable)
#   - .claude/settings.local.json     — Claude Code hooks (Stop + PreCompact)
#
# Does not modify $HOME.
#
# Usage: cd /path/to/project && /path/to/setup-memory.sh
#
# Requires: python3, jq
# Compatible with Bash 3.2 (macOS): no mapfile/readarray.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENTS_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

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
  echo "Palace initialised at $palace_path"
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
      echo "  cd /your/project && $0          # full setup"
      echo "  cd /your/project && $0 mine     # mine project files (setup must be done first)"
      echo ""
      echo "Full setup installs mempalace (if needed) and configures:"
      echo "  .mempalace/                     — project-local palace data"
      echo "  .mempalace/hooks/               — save and precompact hook scripts"
      echo "  .mempalaceignore                — ignore patterns for mining"
      echo "  .cursor/mcp.json                — Cursor project MCP"
      echo "  .cursor/hooks.json              — Cursor hooks (stop + preCompact)"
      echo "  .mcp.json                       — Claude Code project MCP (fallback)"
      echo "  .claude/settings.local.json     — Claude Code auto-save hooks"
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
      mine_project "$py" "$project_root" "$palace_path"
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

  # ── Step 3: Initialise the palace ─────────────────────────────────────────

  if [[ -d "$palace_path" && -f "$palace_path/chroma.sqlite3" ]]; then
    echo ""
    echo "Palace already initialised at $palace_path"
    read -r -p "Re-run mempalace init? [y/N] " do_reinit
    if [[ "${do_reinit:-n}" =~ ^[Yy] ]]; then
      init_palace "$py" "$project_root" "$palace_path"
    fi
  else
    init_palace "$py" "$project_root" "$palace_path"
  fi

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

  # ── Step 5: MCP servers (always configured — mempalace needs them) ──────

  echo ""
  echo "── Configuring MCP servers ──"
  merge_cursor_mcp_mempalace "$cursor_mcp" "$py" "$palace_path"
  setup_claude_mcp "$py" "$palace_path" "$claude_mcp"

  # ── Step 7: Mine project (optional) ──────────────────────────────────────

  echo ""
  read -r -p "Mine this project's files into the palace now? [Y/n] " a_mine
  if [[ "${a_mine:-y}" =~ ^[Yy] ]]; then
    mine_project "$py" "$project_root" "$palace_path"
  fi

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
  echo ""
  echo "  Cursor:"
  echo "    MCP:   $cursor_mcp"
  echo "    Hooks: $cursor_hooks"
  echo ""
  echo "  Claude Code:"
  if command -v claude >/dev/null 2>&1; then
    echo "    MCP:   registered via claude CLI (project scope)"
  else
    echo "    MCP:   $claude_mcp"
  fi
  echo "    Hooks: $claude_settings"
  echo ""
  echo "  Next steps:"
  echo "    1. Restart Cursor and Claude Code to load the MCP server."
  echo "    2. Verify mempalace tools are available (19 MCP tools)."
  echo "    3. Mine more data:  $0 mine"
  echo "$bar"
}

main "$@"
