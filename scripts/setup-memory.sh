#!/usr/bin/env bash
# Configure mempalace memory system for both Claude Code and Cursor.
#
# Installs mempalace (if not present), initialises a project-local palace,
# registers the MCP server for both editors, and sets up auto-save hooks.
#
# Run from the repository/project root you want to configure (current working directory).
# Writes:
#   - .mempalace/                     — project-local palace data
#   - .mempalaceignore                — ignore patterns for mining (node_modules, etc.)
#   - .cursor/mcp.json                — Cursor project MCP (mempalace server merged in)
#   - .cursor/hooks.json              — Cursor hooks (stop + preCompact)
#   - .cursor/rules/mempalace.mdc     — Cursor auto-save rules
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

# Resolve the system python, escaping any active virtualenv.
# The MCP server command and all imports must use this path so mempalace is
# available globally regardless of per-project venvs.
resolve_python() {
  local py=""

  # If a virtualenv is active, look outside it for the system interpreter.
  if [[ -n "${VIRTUAL_ENV:-}" || -n "${CONDA_PREFIX:-}" ]]; then
    # Strip the venv/conda bin dir from PATH and search again.
    local clean_path
    clean_path="$(echo "$PATH" \
      | tr ':' '\n' \
      | grep -v "${VIRTUAL_ENV:-__none__}" \
      | grep -v "${CONDA_PREFIX:-__none__}" \
      | tr '\n' ':')"
    for candidate in python3 python; do
      py="$(PATH="$clean_path" command -v "$candidate" 2>/dev/null)" && break
    done
  fi

  # Fallback / no venv: normal lookup.
  if [[ -z "$py" ]]; then
    for candidate in python3 python; do
      if command -v "$candidate" >/dev/null 2>&1; then
        py="$(command -v "$candidate")"
        break
      fi
    done
  fi

  [[ -n "$py" ]] || die "python3 not found in PATH"

  # Final guard: reject interpreters that live inside a virtualenv directory.
  local real_py
  real_py="$(readlink -f "$py" 2>/dev/null || echo "$py")"
  if [[ "$real_py" == */envs/* || "$real_py" == */.venv/* || "$real_py" == */venv/* ]]; then
    die "resolved python ($real_py) appears to be inside a virtualenv — install a system python first"
  fi

  echo "$py"
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
  echo ""
  echo "Running mempalace init …"
  MEMPALACE_PALACE_PATH="$palace_path" "$py" -m mempalace init "$project_root" \
    || die "mempalace init failed"
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

# ─── Cursor auto-save rules ─────────────────────────────────────────────────

write_cursor_rules() {
  local rules_dir="$1/.cursor/rules"
  local rules_file="$rules_dir/mempalace.mdc"
  mkdir -p "$rules_dir"

  cat >"$rules_file" <<'MDC'
---
description: Mempalace memory system — persistent context across conversations
globs: ["**/*"]
alwaysApply: true
---

# Mempalace Memory System

You have access to the **mempalace** MCP server for persistent memory across conversations. Use it proactively — do not wait for the user to ask.

## Start of conversation

Search mempalace for context relevant to the current task before beginning work. Load any prior decisions, discoveries, or preferences that apply.

## During conversation

When you make important decisions, encounter surprising behaviour, or the user shares preferences or corrections — save them to mempalace immediately using the MCP tools. Do not batch saves for the end.

## End of conversation

Before the conversation ends, save a summary of:
- Key decisions made and their rationale
- Changes implemented and why
- Unfinished work or known issues
- Any new user preferences or corrections

## Long conversations

If the conversation is getting long, proactively save important context to mempalace to prevent information loss if the context window compresses.
MDC

  echo "Wrote $rules_file"
}

# ─── Cursor hooks ────────────────────────────────────────────────────────────

merge_cursor_hooks() {
  local hooks_path="$1" save_cmd="$2" precompact_cmd="$3"
  local tmp
  tmp="$(mktemp)"
  mkdir -p "$(dirname "$hooks_path")"

  if [[ -f "$hooks_path" ]]; then
    jq --arg save "$save_cmd" --arg precompact "$precompact_cmd" '
      .version = (.version // 1) |
      .hooks = (.hooks // {}) |

      # Replace any existing mempalace stop hook
      .hooks.stop = (
        [(.hooks.stop // [])[] | select(.command | contains("mempalace save") | not)] +
        [{ command: $save }]
      ) |

      # Replace any existing mempalace preCompact hook
      .hooks.preCompact = (
        [(.hooks.preCompact // [])[] | select(.command | contains("mempalace save") | not)] +
        [{ command: $precompact }]
      )
    ' "$hooks_path" >"$tmp" || die "jq failed on $hooks_path (invalid JSON?)"
  else
    jq -n --arg save "$save_cmd" --arg precompact "$precompact_cmd" '{
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

# ─── Claude Code hooks ──────────────────────────────────────────────────────

# Build the inline shell command that the hook will execute.
# Uses the resolved system python and absolute palace path so hooks work
# regardless of cwd or virtualenv state.
build_hook_command() {
  local py="$1" palace_path="$2" mode="$3"
  echo "$py -m mempalace save --palace $palace_path --mode $mode"
}

merge_claude_hooks() {
  local settings_path="$1" save_cmd="$2" precompact_cmd="$3"
  local tmp
  tmp="$(mktemp)"
  mkdir -p "$(dirname "$settings_path")"

  if [[ -f "$settings_path" ]]; then
    jq --arg save "$save_cmd" --arg precompact "$precompact_cmd" '
      .hooks = (.hooks // {}) |

      # Replace any existing mempalace Stop hook (match by "mempalace save")
      .hooks.Stop = (
        [(.hooks.Stop // [])[] | select((.hooks // []) | all(.command | contains("mempalace save") | not))] +
        [{ matcher: "*", hooks: [{ type: "command", command: $save, timeout: 30 }] }]
      ) |

      # Replace any existing mempalace PreCompact hook
      .hooks.PreCompact = (
        [(.hooks.PreCompact // [])[] | select((.hooks // []) | all(.command | contains("mempalace save") | not))] +
        [{ hooks: [{ type: "command", command: $precompact, timeout: 30 }] }]
      )
    ' "$settings_path" >"$tmp" || die "jq failed on $settings_path (invalid JSON?)"
  else
    jq -n --arg save "$save_cmd" --arg precompact "$precompact_cmd" '{
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
*.swp
*.swo

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
  if [[ -f "$ignore_file" ]]; then
    echo ".mempalaceignore already exists — skipping."
    return
  fi
  printf '%s' "$IGNORE_PATTERNS" >"$ignore_file"
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
  local claude_mcp="$5" claude_settings="$6" cursor_rules="$7" ignore_file="$8"

  # mempalace importable
  check_mempalace_installed "$py" || return 1
  # Palace directory
  [[ -d "$palace_path" ]] || return 1
  # Ignore file
  [[ -f "$ignore_file" ]] || return 1
  # Cursor MCP entry
  [[ -f "$cursor_mcp" ]] \
    && jq -e '.mcpServers.mempalace' "$cursor_mcp" >/dev/null 2>&1 || return 1
  # Cursor hooks
  [[ -f "$cursor_hooks" ]] \
    && jq -e '.hooks.stop' "$cursor_hooks" >/dev/null 2>&1 || return 1
  # Cursor rules
  [[ -f "$cursor_rules" ]] || return 1
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
      echo "  .mempalaceignore                — ignore patterns for mining"
      echo "  .cursor/mcp.json                — Cursor project MCP"
      echo "  .cursor/hooks.json              — Cursor hooks (stop + preCompact)"
      echo "  .cursor/rules/mempalace.mdc     — Cursor auto-save rules"
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
  local cursor_rules="$project_root/.cursor/rules/mempalace.mdc"
  local claude_mcp="$project_root/.mcp.json"
  local claude_settings="$project_root/.claude/settings.local.json"
  local ignore_file="$project_root/.mempalaceignore"

  print_intro "$project_root"

  # ── Pre-flight: detect existing setup ─────────────────────────────────────

  if is_fully_setup "$py" "$palace_path" "$cursor_mcp" "$cursor_hooks" \
                    "$claude_mcp" "$claude_settings" "$cursor_rules" "$ignore_file"; then
    local ver
    ver="$(get_mempalace_version "$py")"
    echo "mempalace $ver is already fully configured for this project."
    echo ""
    echo "  Palace:         $palace_path"
    echo "  Cursor MCP:     $cursor_mcp"
    echo "  Cursor hooks:   $cursor_hooks"
    echo "  Cursor rules:   $cursor_rules"
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

  # ── Step 2: Initialise the palace ─────────────────────────────────────────

  if [[ -d "$palace_path" && -f "$palace_path/config.json" ]]; then
    echo ""
    echo "Palace already initialised at $palace_path"
    read -r -p "Re-run mempalace init? [y/N] " do_reinit
    if [[ "${do_reinit:-n}" =~ ^[Yy] ]]; then
      init_palace "$py" "$project_root" "$palace_path"
    fi
  else
    init_palace "$py" "$project_root" "$palace_path"
  fi

  # ── Step 3: Write .mempalaceignore ─────────────────────────────────────────

  echo ""
  write_mempalaceignore "$project_root"

  # ── Step 4: Build hook commands (shared by both editors) ──────────────────

  local save_cmd precompact_cmd
  save_cmd="$(build_hook_command "$py" "$palace_path" stop)"
  precompact_cmd="$(build_hook_command "$py" "$palace_path" precompact)"

  # ── Step 5: Cursor — MCP + hooks + rules ─────────────────────────────────

  echo ""
  echo "── Cursor ──"
  merge_cursor_mcp_mempalace "$cursor_mcp" "$py" "$palace_path"
  merge_cursor_hooks "$cursor_hooks" "$save_cmd" "$precompact_cmd"
  write_cursor_rules "$project_root"

  # ── Step 6: Claude Code — MCP + hooks ─────────────────────────────────────

  echo ""
  echo "── Claude Code ──"
  setup_claude_mcp "$py" "$palace_path" "$claude_mcp"
  merge_claude_hooks "$claude_settings" "$save_cmd" "$precompact_cmd"

  # ── Step 6: Mine project (optional) ──────────────────────────────────────

  echo ""
  read -r -p "Mine this project's files into the palace now? [y/N] " a_mine
  if [[ "${a_mine:-n}" =~ ^[Yy] ]]; then
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
  echo "    Rules: $cursor_rules"
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
