#!/usr/bin/env bash
# Diagnose the health of what the Byrde Agents setup scripts configured —
# GitHub (the gh CLI), and the Figma, Google Analytics and Jira tools — for
# every harness init.sh chose (see lib/harness.sh).
#
# Only tools that are ACTUALLY set up are validated. The gitignored manifest
# (.manifest.local.yml, written by setup-*.sh and pruned by their uninstall) is
# the source of truth: a tool whose capability key is absent — never installed,
# or installed and later uninstalled — is omitted from the report entirely, so
# a leftover directory never produces phantom checks. A key present with its
# files missing surfaces as drift.
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
# shellcheck source=lib/harness.sh
. "$SCRIPT_DIR/lib/harness.sh"
# shellcheck source=lib/mcp.sh
. "$SCRIPT_DIR/lib/mcp.sh"

TOOL_VERSION="0.1.0"
PROG_NAME="$(basename "${BASH_SOURCE[0]}")"

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

# check_mcp <server> <fail|warn> <fix hint> — the server is registered for every
# selected harness. Antigravity skips servers it cannot carry (a token from the
# environment), so its absence there is a note, not a fault.
check_mcp() {
  local name="$1" level="$2" hint="$3" h file
  for h in $(harness_selected); do
    file="$(harness_mcp_file "$h")"
    if harness_mcp_has "$PROJECT_ROOT" "$h" "$name"; then
      pass "$(harness_label "$h") MCP: $name in $file"
    elif [[ "$h" == "claude" ]] && claude_mcp_has "$name"; then
      pass "$(harness_label "$h") MCP: $name registered via claude CLI"
    else
      "$level" "$(harness_label "$h") MCP: $name missing from $file — $hint"
    fi
  done
}

# Is rule <name> installed for harness <h>?
rule_installed() {
  local h="$1" name="$2" path
  case "$h" in
    codex) grep -qF "<!-- $HARNESS_MARK:rule $name -->" "$PROJECT_ROOT/AGENTS.md" 2>/dev/null ;;
    antigravity) [[ -f "$PROJECT_ROOT/.agents/rules/$name.md" || -f "$PROJECT_ROOT/.agent/rules/$name.md" ]] ;;
    *) path="$(harness_rule_path "$h" "$name")"; [[ -f "$PROJECT_ROOT/$path" ]] ;;
  esac
}

# check_rule <name> <label> — the rule is installed for every selected harness.
check_rule() {
  local name="$1" label="$2" h
  for h in $(harness_selected); do
    if rule_installed "$h" "$name"; then
      pass "$(harness_label "$h") rule: $label ($(harness_rule_where "$h" "$name"))"
    else
      warn "$(harness_label "$h") rule: $label missing ($(harness_rule_where "$h" "$name")) — run init.sh"
    fi
  done
}

# ─── Harness checks ──────────────────────────────────────────────────────────

check_harnesses() {
  echo ""
  echo "Harnesses"
  echo "---------"
  local h saved
  saved="$(harness_saved)"
  if [[ -n "$saved" ]]; then
    pass "Selected: $saved (from .workspace.agents.json)"
  else
    warn "No harness choice saved — assuming '$HARNESS_DEFAULT'; run init.sh to choose"
  fi
  for h in $(harness_selected); do
    if rule_installed "$h" global; then
      pass "$(harness_label "$h"): rules installed ($(harness_rule_where "$h" "*" | sed 's/section \*/sections/'))"
    else
      fail "$(harness_label "$h"): rules missing — run init.sh"
    fi
    if [[ -f "$PROJECT_ROOT/$(harness_skills_dir "$h")/develop/SKILL.md" ]]; then
      pass "$(harness_label "$h"): practice skills in $(harness_skills_dir "$h")/"
    else
      fail "$(harness_label "$h"): practice skills missing from $(harness_skills_dir "$h")/ — run init.sh"
    fi
    if [[ "$h" == "claude" ]]; then
      if json_has "$PROJECT_ROOT/.claude/settings.json" '.hooks.PostToolUse'; then
        pass "$(harness_label "$h"): hooks in .claude/settings.json"
      else
        warn "$(harness_label "$h"): rules re-injection hook missing — run init.sh"
      fi
    elif harness_supports_hooks "$h"; then
      if harness_hooks_has "$PROJECT_ROOT" "$h"; then
        pass "$(harness_label "$h"): hooks in $(harness_hook_file "$h")"
      else
        warn "$(harness_label "$h"): hooks missing from $(harness_hook_file "$h") — run init.sh"
      fi
    fi
  done
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

  # The always-on rule should be installed for every harness.
  check_rule workspace "workspace routing"
}

# ─── GitHub checks ───────────────────────────────────────────────────────────

check_github() {
  local pr_skill="$SKILLS_DIR/github-projects/SKILL.md" h configured=0 out

  # GitHub is "set up" if the always-on source-control rule is installed or
  # github-projects is in the manifest.
  for h in $HARNESS_ALL; do
    rule_installed "$h" github-source-control && configured=1
  done
  [[ "$configured" -eq 1 ]] || manifest_has github-projects || return 0

  echo ""
  echo "GitHub"
  echo "------"

  # Source control — an always-on rule (installed by init.sh), not a skill.
  check_rule github-source-control "source control (always-on)"

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

  # An older init registered a GitHub MCP server. Nothing drives it now.
  for h in $HARNESS_ALL; do
    if _mcp_github_is_ours "$PROJECT_ROOT" "$h"; then
      warn "$(harness_label "$h"): old GitHub MCP server in $(harness_mcp_file "$h") — re-run init.sh to remove it"
    fi
  done

  # gh CLI, run the way the agents run it: as this workspace's account.
  if ! has_cmd gh; then
    fail "gh CLI not installed"
    return
  fi
  pass "gh CLI available"

  local account
  account="$(gh_workspace_account)"
  if out="$(cd "$PROJECT_ROOT" && "$SCRIPT_DIR/gh/gh.sh" api user --jq .login 2>&1)"; then
    if [[ -n "$account" ]]; then
      pass "gh auth: logged in as $out (the account this workspace names)"
    else
      pass "gh auth: logged in as $out (the active account)"
    fi
  else
    fail "gh auth: ${out%%$'\n'*} — run: gh auth login"
  fi
}

# The account the workspace names, or nothing.
gh_workspace_account() {
  [[ -n "${BYRDE_GH_ACCOUNT:-}" ]] && { echo "$BYRDE_GH_ACCOUNT"; return 0; }
  [[ -f "$WORKSPACE_FILE" ]] || return 0
  jq -r '.githubAccount // empty' "$WORKSPACE_FILE" 2>/dev/null || true
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

  check_mcp figma fail "re-run setup-figma.sh"

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
  check_mcp analytics-mcp warn "re-run setup-google-analytics.sh"

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
  check_mcp atlassian warn "re-run setup-jira.sh"

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

# ─── Main ────────────────────────────────────────────────────────────────────

main() {
  case "${1:-}" in
    -h | --help | help)
      echo "$PROG_NAME · Byrde Agents v$TOOL_VERSION"
      echo ""
      echo "Usage:"
      echo "  cd /your/project && $0"
      echo ""
      echo "Checks the configuration and health of:"
      echo "  GitHub     (source-control rule via init.sh, the gh CLI; projects via setup-github-project.sh)"
      echo "  Figma      (setup-figma.sh)"
      echo "  Analytics  (setup-google-analytics.sh)"
      echo "  Jira       (setup-jira.sh)"
      exit 0
      ;;
  esac

  has_cmd jq   || { echo "error: jq is required" >&2; exit 1; }
  has_cmd curl || { echo "error: curl is required" >&2; exit 1; }

  PROJECT_ROOT="$(pwd -P)"

  local bar
  bar="$(printf '%*s' 68 '' | tr ' ' '=')"
  echo "$bar"
  echo "  $PROG_NAME · Byrde Agents  v$TOOL_VERSION"
  echo ""
  printf '  %-16s %s\n' "Project Root" "$PROJECT_ROOT"
  printf '  %-16s %s\n' "Layout" "$(layout_describe)"
  printf '  %-16s %s\n' "Harnesses" "$(harness_selected)"
  echo "$bar"

  check_harnesses
  check_workspace
  check_github
  check_figma
  check_google_analytics
  check_jira

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
