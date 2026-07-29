#!/usr/bin/env bash
# Diagnose the health of the MCP servers configured by the Byrde Agents
# setup scripts (GitHub, Figma, Mempalace) for both Cursor and Claude Code.
#
# Only tools that are ACTUALLY set up are validated. The gitignored manifest
# (.manifest.local.yml, written by setup-*.sh and pruned by their uninstall) is
# the source of truth: a tool whose capability key is absent — never installed,
# or installed and later uninstalled — is omitted from the report entirely, so
# a leftover directory (e.g. a preserved .mempalace/ palace) never produces
# phantom checks. A key present with its files missing surfaces as drift.
#
# Run from the repository/project root:
#   cd /path/to/project && /path/to/doctor.sh
#
# Requires: jq, curl
# Compatible with Bash 3.2 (macOS): no mapfile/readarray.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENTS_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# Resolve mono- vs multi-repo layout (sets SKILLS_DIR + MANIFEST_FILE) BEFORE
# sourcing the manifest helper, which reads MANIFEST_FILE.
# shellcheck source=lib/layout.sh
. "$SCRIPT_DIR/lib/layout.sh"
# shellcheck source=lib/workspace.sh
. "$SCRIPT_DIR/lib/workspace.sh"
resolve_layout
# shellcheck source=lib/manifest.sh
. "$SCRIPT_DIR/lib/manifest.sh"

TOOL_VERSION="0.1.0"
PROG_NAME="$(basename "${BASH_SOURCE[0]}")"

GITHUB_MCP_URL="https://api.githubcopilot.com/mcp/"
FIGMA_MCP_URL="https://mcp.figma.com/mcp"
JIRA_MCP_URL="https://mcp.atlassian.com/v1/sse"
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

# Run a command with a timeout, portably. Uses GNU `timeout`/`gtimeout` when
# available, otherwise falls back to a perl alarm wrapper (perl ships with
# macOS). A pending alarm timer survives `exec`, and SIGALRM's default action
# terminates the process — so the exec'd command is killed after `secs`.
run_with_timeout() {
  local secs="$1"
  shift
  if has_cmd timeout; then
    timeout "$secs" "$@"
  elif has_cmd gtimeout; then
    gtimeout "$secs" "$@"
  elif has_cmd perl; then
    perl -e 'my $s = shift; alarm $s; exec @ARGV or exit 127' "$secs" "$@"
  else
    # No timeout mechanism available — run unbounded as a last resort.
    "$@"
  fi
}

# Check if a key exists in a JSON file. Returns 0 if present.
json_has() {
  local file="$1" path="$2"
  [[ -f "$file" ]] && jq -e "$path" "$file" >/dev/null 2>&1
}

# Send an MCP initialize request to an HTTP endpoint.
# Returns: 0 = healthy, 1 = auth error, 2 = unreachable, 3 = unexpected
http_mcp_check() {
  local url="$1"
  shift
  local -a extra_args=("$@")
  local http_code
  # Expand extra_args safely under `set -u`: an empty array would otherwise
  # trigger "unbound variable" on Bash 3.2 (macOS) when called with no headers.
  http_code="$(curl -s --max-time 10 -o /dev/null -w "%{http_code}" \
    -X POST \
    -H "Content-Type: application/json" \
    -H "Accept: application/json, text/event-stream" \
    ${extra_args[@]+"${extra_args[@]}"} \
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

# ─── Workspace checks ────────────────────────────────────────────────────────

check_workspace() {
  # Configured iff the map exists at the context root (no manifest entry — the
  # workspace capability is a rule + a map, not a skill).
  [[ -f "$WORKSPACE_FILE" ]] || return 0

  echo ""
  echo "Workspace"
  echo "---------"

  if jq -e . "$WORKSPACE_FILE" >/dev/null 2>&1; then
    local mode count
    mode="$(jq -r '.mode // "?"' "$WORKSPACE_FILE" 2>/dev/null)"
    count="$(jq -r '.repos | length' "$WORKSPACE_FILE" 2>/dev/null)"
    pass "Map: .workspace.agents.json (mode: $mode, $count repo(s))"
    # Drift: a listed repo path that no longer exists on disk.
    local missing
    missing="$(jq -r '.repos[] | select(.path != ".") | .path' "$WORKSPACE_FILE" 2>/dev/null \
      | while IFS= read -r p; do [[ -d "$WORKSPACE_ROOT/$p" ]] || echo "$p"; done)"
    if [[ -n "$missing" ]]; then
      warn "Map lists repo(s) not on disk: $(echo "$missing" | tr '\n' ' ')— re-run init.sh to refresh"
    fi
  else
    fail "Map: .workspace.agents.json is not valid JSON — re-run init.sh"
  fi

  # The always-on rule should be installed in the editor rule dirs.
  if [[ -f "$PROJECT_ROOT/.claude/rules/workspace.md" ]]; then
    pass "Rule: .claude/rules/workspace.md"
  else
    warn "Rule: .claude/rules/workspace.md missing — run init.sh"
  fi
}

# ─── GitHub checks ───────────────────────────────────────────────────────────

check_github() {
  local sc_rule="$PROJECT_ROOT/.claude/rules/github-source-control.md"
  local pr_skill="$SKILLS_DIR/github-projects/SKILL.md"

  # GitHub is "set up" if the always-on source-control rule is installed, the
  # account-wide MCP is registered, or github-projects is in the manifest.
  [[ -f "$sc_rule" ]] || json_has "$CLAUDE_MCP" '.mcpServers.github' \
    || json_has "$CURSOR_MCP" '.mcpServers.github' || manifest_has github-projects || return 0

  echo ""
  echo "GitHub"
  echo "------"

  # Source control — an always-on rule (installed by init.sh), not a skill.
  if [[ -f "$sc_rule" ]]; then
    pass "Source control: .claude/rules/github-source-control.md (always-on rule)"
  else
    warn "Source control: rule .claude/rules/github-source-control.md missing — run init.sh"
  fi

  # github-projects — manifest-gated skill (installed by setup-github-project.sh).
  if manifest_has github-projects; then
    if [[ -f "$pr_skill" ]]; then
      pass "Skill: skills/github-projects/SKILL.md"
    else
      fail "Skill: github-projects in manifest but SKILL.md missing — re-run setup-github-project.sh"
    fi
  else
    skip "github-projects not installed (optional — setup-github-project.sh)"
  fi

  # Cursor MCP config
  if json_has "$CURSOR_MCP" '.mcpServers.github'; then
    pass "Cursor MCP: mcpServers.github configured"
  else
    warn "Cursor MCP: mcpServers.github missing from $CURSOR_MCP — run init.sh"
  fi

  # Claude Code MCP config
  if json_has "$CLAUDE_MCP" '.mcpServers.github'; then
    pass "Claude MCP: mcpServers.github configured in .mcp.json"
  elif claude_mcp_has github; then
    pass "Claude MCP: mcpServers.github registered via claude CLI"
  else
    warn "Claude MCP: mcpServers.github missing — run init.sh"
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

  # HTTP health (GitHub uses OAuth via the client — 401 is expected without a session)
  local rc=0
  http_mcp_check "$GITHUB_MCP_URL" || rc=$?
  case $rc in
    0) pass "MCP server: $GITHUB_MCP_URL responding" ;;
    1) pass "MCP server: $GITHUB_MCP_URL reachable (auth handled by editor on first use)" ;;
    2) fail "MCP server: $GITHUB_MCP_URL unreachable" ;;
    *) warn "MCP server: $GITHUB_MCP_URL returned unexpected status" ;;
  esac
}

# ─── Figma checks ────────────────────────────────────────────────────────────

check_figma() {
  local figma_skill="$SKILLS_DIR/figma/SKILL.md"

  # Gate: the manifest is the source of truth. If Figma isn't recorded there,
  # it isn't set up in this checkout — omit the section entirely. The retired
  # figma-design-system / figma-design-file names still gate it so a stale
  # install gets reported rather than silently skipped.
  manifest_has figma || manifest_has figma-design-system \
    || manifest_has figma-design-file || return 0

  echo ""
  echo "Figma"
  echo "-----"

  if manifest_has figma; then
    if [[ -f "$figma_skill" ]]; then
      pass "Skill: skills/figma/SKILL.md"
    else
      fail "Skill: figma in manifest but SKILL.md missing — re-run setup-figma.sh"
    fi
  else
    fail "Skill: figma not installed — re-run setup-figma.sh"
  fi

  # figma-design-system + figma-design-file merged into `figma`. Flag leftovers
  # from an older install: two skills claiming the same operations misroutes.
  local legacy
  for legacy in figma-design-system figma-design-file; do
    if manifest_has "$legacy" || [[ -f "$SKILLS_DIR/$legacy/SKILL.md" ]]; then
      fail "Skill: $legacy is retired (merged into figma) — re-run setup-figma.sh to clean it up"
    fi
  done

  # figma-use overlay (vendored from figma/mcp-server-guide)
  local figma_use="$SKILLS_DIR/figma-use/SKILL.md"
  if [[ -f "$figma_use" ]]; then
    local upstream="$SKILLS_DIR/figma-use/.upstream"
    if [[ -f "$upstream" ]]; then
      local sha
      sha="$(sed -n 's/^commit: //p' "$upstream" 2>/dev/null | head -1)"
      pass "Skill: skills/figma-use/SKILL.md (upstream ${sha:0:7})"
    else
      pass "Skill: skills/figma-use/SKILL.md"
    fi
  else
    fail "Skill: skills/figma-use/SKILL.md missing — re-run setup-figma.sh to vendor the upstream skill"
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

# ─── Google Analytics checks ─────────────────────────────────────────────────

check_google_analytics() {
  # manifest-gated, like github-projects / figma — only report when installed.
  manifest_has google-analytics || return 0

  echo ""
  echo "Google Analytics"
  echo "----------------"

  # Skill
  if [[ -f "$SKILLS_DIR/google-analytics/SKILL.md" ]]; then
    pass "Skill: skills/google-analytics/SKILL.md"
  else
    fail "Skill: google-analytics in manifest but SKILL.md missing — re-run setup-google-analytics.sh"
  fi

  # MCP registration (local stdio server — no health ping; just confirm config)
  if json_has "$CLAUDE_MCP" '.mcpServers["analytics-mcp"]'; then
    pass "Claude MCP: mcpServers[\"analytics-mcp\"] configured in .mcp.json"
  else
    warn "Claude MCP: mcpServers[\"analytics-mcp\"] missing — re-run setup-google-analytics.sh"
  fi
  if json_has "$CURSOR_MCP" '.mcpServers["analytics-mcp"]'; then
    pass "Cursor MCP: mcpServers[\"analytics-mcp\"] configured"
  else
    warn "Cursor MCP: mcpServers[\"analytics-mcp\"] missing — re-run setup-google-analytics.sh"
  fi

  # Tooling + credentials
  if has_cmd pipx; then
    pass "pipx installed (runs analytics-mcp)"
  else
    fail "pipx not installed — the analytics-mcp server cannot start"
  fi
  if has_cmd gcloud; then
    pass "gcloud installed"
  else
    warn "gcloud not installed — needed to (re)establish Application Default Credentials"
  fi
  if [[ -f "${GOOGLE_APPLICATION_CREDENTIALS:-}" \
     || -f "$HOME/.config/gcloud/application_default_credentials.json" ]]; then
    pass "Application Default Credentials present"
  else
    warn "Application Default Credentials missing — run: gcloud auth application-default login --scopes https://www.googleapis.com/auth/analytics.readonly,https://www.googleapis.com/auth/cloud-platform"
  fi
}

# ─── Jira checks ─────────────────────────────────────────────────────────────

check_jira() {
  # manifest-gated, like github-projects / figma / google-analytics — only
  # report when installed.
  manifest_has jira || return 0

  echo ""
  echo "Jira"
  echo "----"

  # Skill
  if [[ -f "$SKILLS_DIR/jira/SKILL.md" ]]; then
    pass "Skill: skills/jira/SKILL.md"
  else
    fail "Skill: jira in manifest but SKILL.md missing — re-run setup-jira.sh"
  fi

  # MCP registration (remote OAuth server — config-only, health pinged below)
  if json_has "$CLAUDE_MCP" '.mcpServers.atlassian'; then
    pass "Claude MCP: mcpServers.atlassian configured in .mcp.json"
  elif claude_mcp_has atlassian; then
    pass "Claude MCP: mcpServers.atlassian registered via claude CLI"
  else
    warn "Claude MCP: mcpServers.atlassian missing — re-run setup-jira.sh"
  fi
  if json_has "$CURSOR_MCP" '.mcpServers.atlassian'; then
    pass "Cursor MCP: mcpServers.atlassian configured"
  else
    warn "Cursor MCP: mcpServers.atlassian missing — re-run setup-jira.sh"
  fi

  # HTTP health (Atlassian uses OAuth via the client — 401 is expected without a session)
  local rc=0
  http_mcp_check "$JIRA_MCP_URL" || rc=$?
  case $rc in
    0) pass "MCP server: $JIRA_MCP_URL responding" ;;
    1) pass "MCP server: $JIRA_MCP_URL reachable (auth handled by editor on first use)" ;;
    2) fail "MCP server: $JIRA_MCP_URL unreachable" ;;
    *) warn "MCP server: $JIRA_MCP_URL returned unexpected status" ;;
  esac
}

# ─── Mempalace checks ───────────────────────────────────────────────────────

check_mempalace() {
  local palace_path="$PROJECT_ROOT/.mempalace"

  # Gate: the manifest is the source of truth. The `memory` key is removed on
  # `setup-memory.sh uninstall`, so an uninstalled palace disappears from the
  # report even though uninstall deliberately PRESERVES the .mempalace/
  # directory (it holds committed memories) — a stale dir is no longer enough
  # to trigger phantom checks.
  manifest_has memory || return 0

  echo ""
  echo "Mempalace"
  echo "---------"

  # Palace directory
  if [[ -d "$palace_path" ]]; then
    pass "Palace directory: $palace_path"
  else
    warn "Palace directory: $palace_path not found (run setup-memory.sh)"
  fi

  # Memory skill
  if [[ -f "$SKILLS_DIR/memory/SKILL.md" ]]; then
    pass "Skill: skills/memory/SKILL.md"
  else
    warn "Skill: skills/memory/SKILL.md missing — re-run setup-memory.sh to install it"
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
    | run_with_timeout 5 "$py" -m mempalace.mcp_server --palace "$palace_path" 2>/dev/null \
    | head -1)" || true
  if [[ -n "$mcp_response" ]] && echo "$mcp_response" | jq -e '.result' >/dev/null 2>&1; then
    pass "MCP server: stdio handshake succeeded"
  elif [[ -n "$mcp_response" ]]; then
    warn "MCP server: process responded but handshake unclear"
  else
    warn "MCP server: stdio handshake timed out or failed (may work fine inside the editor)"
  fi

  # Concurrency: mempalace's ChromaDB backend is single-writer. More than one
  # live server on the same palace = concurrent writers = vector-index drift.
  local srv_count
  srv_count="$(ps aux 2>/dev/null | grep "mempalace.mcp_server" | grep -F -- "$palace_path" | grep -cv grep | tr -d ' ')"
  if [[ "${srv_count:-0}" -gt 1 ]]; then
    warn "Concurrency: $srv_count mempalace servers running on this palace — concurrent writers drift the index. Keep ONE editor/window open on it. (sqlite is safe; 'setup-memory.sh repair' rebuilds.)"
  elif [[ "${srv_count:-0}" -eq 1 ]]; then
    pass "Concurrency: single MCP server on this palace"
  fi

  # Quarantine backups = the index drifted before and self-healed. Harmless to
  # delete; flagged so recurring drift is visible (e.g. multiple servers).
  if ls -d "$palace_path"/*.corrupt-* "$palace_path"/*.drift-* >/dev/null 2>&1; then
    warn "Index: quarantine backups present (past drift) — safe to delete; investigate if recurring."
  fi

  # Portability: sqlite is the committed ground truth; the index is gitignored.
  # On a fresh checkout sqlite is present but the index isn't — rebuild it.
  if [[ -f "$palace_path/chroma.sqlite3" ]] \
    && ! find "$palace_path" -mindepth 1 -maxdepth 1 -type d \
         -name '*-*-*-*-*' ! -name '*.corrupt-*' ! -name '*.drift-*' 2>/dev/null | grep -q .; then
    warn "Index: chroma.sqlite3 present but no vector index — run 'setup-memory.sh repair' (e.g. after checkout)."
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
      echo "  GitHub     (source-control rule + MCP via init.sh; projects via setup-github-project.sh)"
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
  printf '  %-16s %s\n' "Layout" "$(layout_describe)"
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

  check_workspace
  check_github
  check_figma
  check_google_analytics
  check_jira
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
