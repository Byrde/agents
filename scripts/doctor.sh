#!/usr/bin/env bash
# Diagnose the health of all MCP servers configured by the Byrde Agents
# setup scripts (GitHub, Figma, Mempalace) for both Cursor and Claude Code.
#
# Run from the repository/project root:
#   cd /path/to/project && /path/to/doctor.sh
#
# Requires: jq, curl
# Compatible with Bash 3.2 (macOS): no mapfile/readarray.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENTS_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

TOOL_VERSION="0.1.0"
PROG_NAME="$(basename "${BASH_SOURCE[0]}")"

GITHUB_MCP_URL="https://api.githubcopilot.com/mcp/"
FIGMA_MCP_URL="https://mcp.figma.com/mcp"
MCP_INIT_REQ='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"doctor","version":"0.1.0"}}}'

# ─── Counters ────────────────────────────────────────────────────────────────

PASS=0
FAIL=0
WARN=0
SKIP=0

pass() { printf '  \033[32m✓\033[0m %s\n' "$*"; ((PASS++)) || true; }
fail() { printf '  \033[31m✗\033[0m %s\n' "$*"; ((FAIL++)) || true; }
warn() { printf '  \033[33m⚠\033[0m %s\n' "$*"; ((WARN++)) || true; }
skip() { printf '  \033[90m- %s\033[0m\n' "$*"; ((SKIP++)) || true; }

# ─── Helpers ─────────────────────────────────────────────────────────────────

has_cmd() { command -v "$1" >/dev/null 2>&1; }

# Check if a key exists in a JSON file. Returns 0 if present.
json_has() {
  local file="$1" path="$2"
  [[ -f "$file" ]] && jq -e "$path" "$file" >/dev/null 2>&1
}

# Extract a string value from a JSON file.
json_get() {
  local file="$1" path="$2"
  [[ -f "$file" ]] && jq -r "$path // empty" "$file" 2>/dev/null
}

# Send an MCP initialize request to an HTTP endpoint.
# Returns: 0 = healthy, 1 = auth error, 2 = unreachable, 3 = unexpected
http_mcp_check() {
  local url="$1"
  shift
  local -a extra_args=("$@")
  local http_code
  http_code="$(curl -s --max-time 10 -o /dev/null -w "%{http_code}" \
    -X POST \
    -H "Content-Type: application/json" \
    -H "Accept: application/json, text/event-stream" \
    "${extra_args[@]}" \
    -d "$MCP_INIT_REQ" \
    "$url" 2>/dev/null)" || http_code="000"
  case "$http_code" in
    2[0-9][0-9]) return 0 ;;
    401|403)     return 1 ;;
    000)         return 2 ;;
    *)           return 3 ;;
  esac
}

# Check if a server name appears in `claude mcp list` output.
claude_mcp_has() {
  local name="$1"
  has_cmd claude || return 1
  claude mcp list --scope project 2>/dev/null | grep -qi "$name"
}

# ─── GitHub checks ───────────────────────────────────────────────────────────

check_github() {
  echo ""
  echo "GitHub"
  echo "------"

  # Tool file
  local tool_file="$AGENTS_ROOT/tools/github.md"
  if [[ -f "$tool_file" ]]; then
    pass "Tool file: tools/github.md"
  else
    skip "Tool file: tools/github.md not rendered (run setup-github.sh)"
    # No point checking MCP if the tool was never set up
    return
  fi

  # Cursor MCP config
  if json_has "$CURSOR_MCP" '.mcpServers.github'; then
    pass "Cursor MCP: mcpServers.github configured"
  else
    fail "Cursor MCP: mcpServers.github missing from $CURSOR_MCP"
  fi

  # Claude Code MCP config
  if json_has "$CLAUDE_MCP" '.mcpServers.github'; then
    pass "Claude MCP: mcpServers.github configured in .mcp.json"
  elif claude_mcp_has github; then
    pass "Claude MCP: mcpServers.github registered via claude CLI"
  else
    fail "Claude MCP: mcpServers.github missing"
  fi

  # gh CLI
  if ! has_cmd gh; then
    fail "gh CLI not installed"
    return
  fi
  pass "gh CLI available"

  # gh auth
  if gh auth status -h github.com >/dev/null 2>&1; then
    pass "gh auth: authenticated to github.com"
  else
    fail "gh auth: not logged in — run: gh auth login"
    return
  fi

  # Token validity — extract from whichever config has it
  local token=""
  token="$(json_get "$CURSOR_MCP" '.mcpServers.github.headers.Authorization' | sed 's/^Bearer //')"
  [[ -z "$token" ]] && token="$(json_get "$CLAUDE_MCP" '.mcpServers.github.headers.Authorization' | sed 's/^Bearer //')"

  if [[ -z "$token" ]]; then
    warn "MCP token: could not extract from config — may need to re-run setup-github.sh"
    return
  fi

  # HTTP health
  local rc=0
  http_mcp_check "$GITHUB_MCP_URL" -H "Authorization: Bearer $token" || rc=$?
  case $rc in
    0) pass "MCP server: $GITHUB_MCP_URL responding" ;;
    1) fail "MCP server: $GITHUB_MCP_URL returned 401/403 — token expired, re-run setup-github.sh" ;;
    2) fail "MCP server: $GITHUB_MCP_URL unreachable" ;;
    *) warn "MCP server: $GITHUB_MCP_URL returned unexpected status" ;;
  esac
}

# ─── Figma checks ────────────────────────────────────────────────────────────

check_figma() {
  echo ""
  echo "Figma"
  echo "-----"

  # Tool file
  local tool_file="$AGENTS_ROOT/tools/figma.md"
  if [[ -f "$tool_file" ]]; then
    pass "Tool file: tools/figma.md"
  else
    skip "Tool file: tools/figma.md not rendered (run setup-figma.sh)"
    return
  fi

  # Cursor MCP config
  if json_has "$CURSOR_MCP" '.mcpServers.figma'; then
    pass "Cursor MCP: mcpServers.figma configured"
  else
    fail "Cursor MCP: mcpServers.figma missing from $CURSOR_MCP"
  fi

  # Claude Code MCP config
  if json_has "$CLAUDE_MCP" '.mcpServers.figma'; then
    pass "Claude MCP: mcpServers.figma configured in .mcp.json"
  elif claude_mcp_has figma; then
    pass "Claude MCP: mcpServers.figma registered via claude CLI"
  else
    fail "Claude MCP: mcpServers.figma missing"
  fi

  # HTTP health (Figma uses OAuth via the client — 401 is expected without a session)
  local rc=0
  http_mcp_check "$FIGMA_MCP_URL" || rc=$?
  case $rc in
    0) pass "MCP server: $FIGMA_MCP_URL responding" ;;
    1) pass "MCP server: $FIGMA_MCP_URL reachable (auth handled by editor on first use)" ;;
    2) fail "MCP server: $FIGMA_MCP_URL unreachable" ;;
    *) warn "MCP server: $FIGMA_MCP_URL returned unexpected status" ;;
  esac
}

# ─── Mempalace checks ───────────────────────────────────────────────────────

check_mempalace() {
  echo ""
  echo "Mempalace"
  echo "---------"

  local palace_path="$PROJECT_ROOT/.mempalace"

  # Palace directory
  if [[ -d "$palace_path" ]]; then
    pass "Palace directory: $palace_path"
  else
    skip "Palace directory: $palace_path not found (run setup-memory.sh)"
    return
  fi

  # Ignore file
  local ignore_file="$PROJECT_ROOT/.mempalaceignore"
  if [[ -f "$ignore_file" ]]; then
    pass "Ignore file: .mempalaceignore"
  else
    warn "Ignore file: .mempalaceignore missing — mining may index node_modules, etc."
  fi

  # Python + import
  local py=""
  for candidate in python3 python; do
    if has_cmd "$candidate"; then
      py="$(command -v "$candidate")"
      break
    fi
  done
  if [[ -z "$py" ]]; then
    fail "Python: not found in PATH"
    return
  fi
  pass "Python: $py"

  if "$py" -c "import mempalace" 2>/dev/null; then
    local ver
    ver="$("$py" -c "import mempalace; print(mempalace.__version__)" 2>/dev/null || echo "unknown")"
    pass "mempalace: importable (v$ver)"
  else
    fail "mempalace: not importable — run setup-memory.sh"
    return
  fi

  # Cursor MCP config
  if json_has "$CURSOR_MCP" '.mcpServers.mempalace'; then
    pass "Cursor MCP: mcpServers.mempalace configured"
  else
    fail "Cursor MCP: mcpServers.mempalace missing from $CURSOR_MCP"
  fi

  # Cursor hooks
  local cursor_hooks="$PROJECT_ROOT/.cursor/hooks.json"
  if [[ -f "$cursor_hooks" ]]; then
    local has_stop=false has_precompact=false
    json_has "$cursor_hooks" '.hooks.stop' && has_stop=true
    json_has "$cursor_hooks" '.hooks.preCompact' && has_precompact=true
    if [[ "$has_stop" == "true" && "$has_precompact" == "true" ]]; then
      pass "Cursor hooks: stop + preCompact configured"
    elif [[ "$has_stop" == "true" ]]; then
      warn "Cursor hooks: stop configured, preCompact missing"
    elif [[ "$has_precompact" == "true" ]]; then
      warn "Cursor hooks: preCompact configured, stop missing"
    else
      fail "Cursor hooks: no mempalace hooks in $cursor_hooks"
    fi
  else
    fail "Cursor hooks: $cursor_hooks not found"
  fi

  # Claude Code MCP config
  if json_has "$CLAUDE_MCP" '.mcpServers.mempalace'; then
    pass "Claude MCP: mcpServers.mempalace configured in .mcp.json"
  elif claude_mcp_has mempalace; then
    pass "Claude MCP: mcpServers.mempalace registered via claude CLI"
  else
    fail "Claude MCP: mcpServers.mempalace missing"
  fi

  # Claude Code hooks
  local claude_settings="$PROJECT_ROOT/.claude/settings.local.json"
  if [[ -f "$claude_settings" ]]; then
    local has_stop=false has_precompact=false
    if json_has "$claude_settings" '.hooks.Stop'; then
      has_stop=true
    fi
    if json_has "$claude_settings" '.hooks.PreCompact'; then
      has_precompact=true
    fi
    if [[ "$has_stop" == "true" && "$has_precompact" == "true" ]]; then
      pass "Claude hooks: Stop + PreCompact configured"
    elif [[ "$has_stop" == "true" ]]; then
      warn "Claude hooks: Stop configured, PreCompact missing"
    elif [[ "$has_precompact" == "true" ]]; then
      warn "Claude hooks: PreCompact configured, Stop missing"
    else
      fail "Claude hooks: not configured in $claude_settings"
    fi
  else
    fail "Claude hooks: $claude_settings not found"
  fi

  # MCP server health — try spawning and sending initialize
  local mcp_response=""
  mcp_response="$(printf '%s\n' "$MCP_INIT_REQ" \
    | timeout 5 "$py" -m mempalace.mcp_server --palace "$palace_path" 2>/dev/null \
    | head -1)" || true
  if [[ -n "$mcp_response" ]] && echo "$mcp_response" | jq -e '.result' >/dev/null 2>&1; then
    pass "MCP server: stdio handshake succeeded"
  elif [[ -n "$mcp_response" ]]; then
    warn "MCP server: process responded but handshake unclear"
  else
    warn "MCP server: stdio handshake timed out or failed (may work fine inside the editor)"
  fi
}

# ─── Main ────────────────────────────────────────────────────────────────────

main() {
  case "${1:-}" in
    -h | --help | help)
      echo "$PROG_NAME · Byrde Agents v$TOOL_VERSION"
      echo ""
      echo "Usage:"
      echo "  cd /your/project && $0"
      echo ""
      echo "Checks MCP server configuration and health for:"
      echo "  GitHub     (setup-github.sh)"
      echo "  Figma      (setup-figma.sh)"
      echo "  Mempalace  (setup-memory.sh)"
      exit 0
      ;;
  esac

  has_cmd jq   || { echo "error: jq is required" >&2; exit 1; }
  has_cmd curl || { echo "error: curl is required" >&2; exit 1; }

  PROJECT_ROOT="$(pwd -P)"
  CURSOR_MCP="$PROJECT_ROOT/.cursor/mcp.json"
  CLAUDE_MCP="$PROJECT_ROOT/.mcp.json"

  local bar
  bar="$(printf '%*s' 68 '' | tr ' ' '=')"
  echo "$bar"
  echo "  $PROG_NAME · Byrde Agents  v$TOOL_VERSION"
  echo ""
  printf '  %-16s %s\n' "Project Root" "$PROJECT_ROOT"
  printf '  %-16s %s\n' "Cursor MCP" "$CURSOR_MCP"
  printf '  %-16s %s\n' "Claude MCP" "$CLAUDE_MCP"
  echo "$bar"

  # Config file existence (informational, not scored)
  echo ""
  echo "Config files"
  echo "------------"
  if [[ -f "$CURSOR_MCP" ]]; then
    pass ".cursor/mcp.json exists"
  else
    warn ".cursor/mcp.json not found — no Cursor MCP servers configured"
  fi
  if [[ -f "$CLAUDE_MCP" ]]; then
    pass ".mcp.json exists"
  elif has_cmd claude; then
    pass ".mcp.json absent but claude CLI available (may use project scope)"
  else
    warn ".mcp.json not found — no Claude Code MCP servers configured"
  fi

  check_github
  check_figma
  check_mempalace

  # Summary
  echo ""
  echo "$bar"
  printf '  \033[32m%d passed\033[0m' "$PASS"
  [[ $FAIL -gt 0 ]] && printf '  \033[31m%d failed\033[0m' "$FAIL"
  [[ $WARN -gt 0 ]] && printf '  \033[33m%d warnings\033[0m' "$WARN"
  [[ $SKIP -gt 0 ]] && printf '  \033[90m%d skipped\033[0m' "$SKIP"
  echo ""
  echo "$bar"

  # Exit code: non-zero if any failures
  [[ $FAIL -eq 0 ]]
}

main "$@"
