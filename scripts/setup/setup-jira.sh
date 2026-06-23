#!/usr/bin/env bash
# Configure the jira tool skill: pin a Jira site + project, install the jira
# skill, and register Atlassian's official Remote MCP server in the project
# configs.
#
# Mirrors setup-github-project.sh / setup-google-analytics.sh: it installs a tool
# skill, pins identity (the Jira site + project key), wires the MCP server into
# .mcp.json / .cursor/mcp.json, records the capability in the manifest, and ships
# an uninstall path.
#
# Auth model — NO SECRETS ON DISK (the house invariant):
#   The Atlassian Remote MCP authenticates with OAuth 2.1. Unlike GitHub it
#   SUPPORTS dynamic client registration, so the editor runs the consent flow on
#   first connection and stores nothing in the repo — same spirit as the Figma
#   MCP. The config carries only the public server URL; no token, no cloud ID,
#   no project secret. The cloud ID is resolved live by the skill at preflight
#   via getAccessibleAtlassianResources.
#
# Because there is no ubiquitous Jira CLI (the way `gh` validates GitHub), this
# script does not call the Jira API. Site + project key are prompted with light
# format validation only and may be left blank to pin later — exactly how
# setup-google-analytics.sh treats the GA property.
#
# Run from the folder your agent opens in (the one that contains .agents):
#   cd /your/workspace && /path/to/setup-jira.sh
#
# Writes:
#   - skills/jira/SKILL.md (+ mirrored into .claude/ and .cursor/)
#   - .mcp.json / .cursor/mcp.json — registers the Atlassian MCP server
#
# Requires: jq, python3. Bash 3.2 (macOS) compatible.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENTS_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=lib/layout.sh
. "$SCRIPT_DIR/../lib/layout.sh"
resolve_layout
# shellcheck source=lib/manifest.sh
. "$SCRIPT_DIR/../lib/manifest.sh"
TOOL_DIR="$AGENTS_ROOT/tools"
JIRA_TEMPLATE="$TOOL_DIR/jira.md.template"
JIRA_OUT="$SKILLS_DIR/jira/SKILL.md"

JIRA_MCP_URL="https://mcp.atlassian.com/v1/sse"
TOOL_VERSION="0.1.0"
PROG_NAME="$(basename "${BASH_SOURCE[0]}")"

die() {
  echo "error: $*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing required command: $1 (install or add to PATH)"
}

bar() { printf '%*s' 68 '' | tr ' ' '='; }

print_intro() {
  local b; b="$(bar)"
  echo "$b"
  echo "  $PROG_NAME · Byrde Agents  v$TOOL_VERSION"
  echo ""
  echo "  Pin a Jira site + project and install the jira skill."
  echo "  Registers Atlassian's Remote MCP server (OAuth handled by the editor)."
  echo ""
  printf '  %-16s %s\n' "Context Root" "$WORKSPACE_ROOT"
  printf '  %-16s %s\n' "Layout" "$(layout_describe)"
  echo "$b"
  echo ""
}

# ─── Prompts ─────────────────────────────────────────────────────────────────

# Jira site host, e.g. your-domain.atlassian.net. Accepts a bare host or a full
# URL (https:// and trailing slash/path are stripped). Blank is allowed so
# install can proceed before the site is known; the skill renders a "not yet
# pinned" note in that case.
prompt_site() {
  local sel
  echo "" >&2
  echo "  Jira site host, e.g. your-domain.atlassian.net" >&2
  echo "  (paste the URL from your browser — https:// and any path are trimmed)." >&2
  while true; do
    read -r -p "  Jira site (Enter to skip and pin later): " sel || die "stdin closed"
    [[ -n "$sel" ]] || { echo ""; return 0; }
    # Strip scheme and anything from the first slash onward.
    sel="${sel#https://}"; sel="${sel#http://}"; sel="${sel%%/*}"
    if [[ "$sel" =~ ^[A-Za-z0-9.-]+\.atlassian\.net$ || "$sel" =~ ^[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]; then
      echo "$sel"; return 0
    fi
    echo "  That doesn't look like a host (expected something.atlassian.net)." >&2
  done
}

# Jira project key, e.g. PROJ. Uppercase letters/digits, starting with a letter
# (Jira's own rule). Blank allowed to pin later.
prompt_project_key() {
  local sel
  echo "" >&2
  echo "  Jira project key — the short uppercase prefix on issue IDs (e.g. PROJ" >&2
  echo "  for PROJ-123). Find it in Jira → Project settings → Details." >&2
  while true; do
    read -r -p "  Project key (Enter to skip and pin later): " sel || die "stdin closed"
    [[ -n "$sel" ]] || { echo ""; return 0; }
    sel="$(printf '%s' "$sel" | tr '[:lower:]' '[:upper:]')"
    if [[ "$sel" =~ ^[A-Z][A-Z0-9]+$ ]]; then echo "$sel"; return 0; fi
    echo "  A key is uppercase, starts with a letter, e.g. PROJ." >&2
  done
}

# ─── skill render / sync ─────────────────────────────────────────────────────

render_skill() {
  local template="$1" out="$2" site="$3" project_key="$4"
  [[ -f "$template" ]] || die "missing template: $template"
  mkdir -p "$(dirname "$out")"
  local site_display="$site" key_display="$project_key"
  [[ -n "$site_display" ]] || site_display="(not yet pinned — re-run setup-jira.sh)"
  [[ -n "$key_display" ]] || key_display="(not yet pinned — re-run setup-jira.sh)"
  RENDER_TEMPLATE="$template" RENDER_OUT="$out" \
    RENDER_SITE="$site_display" RENDER_PROJECT_KEY="$key_display" \
    python3 <<'PY'
from pathlib import Path
import os
src = Path(os.environ["RENDER_TEMPLATE"]); dst = Path(os.environ["RENDER_OUT"])
out = (src.read_text()
       .replace("{{SITE}}", os.environ["RENDER_SITE"])
       .replace("{{PROJECT_KEY}}", os.environ["RENDER_PROJECT_KEY"]))
dst.write_text(out); print("Wrote", dst)
PY
}

sync_skill_to_editors() {
  local skill="$1"
  local src="$SKILLS_DIR/$skill"
  [[ -d "$src" ]] || return 0
  local dest
  for dest in "$WORKSPACE_ROOT/.claude/skills" "$WORKSPACE_ROOT/.cursor/skills"; do
    mkdir -p "$dest"; rm -rf "${dest:?}/$skill"; cp -R "$src" "$dest/$skill"
    echo "  skills/$skill → ${dest#"$WORKSPACE_ROOT"/}/$skill"
  done
}

# ─── MCP registration (Atlassian Remote MCP; URL only, OAuth via editor) ──────

_mcp_merge_jira_claude() {
  local path="$1" tmp
  tmp="$(mktemp)"
  mkdir -p "$(dirname "$path")"
  if [[ -f "$path" ]]; then
    jq --arg url "$JIRA_MCP_URL" '
      .mcpServers = (.mcpServers // {}) |
      .mcpServers.atlassian = { type: "sse", url: $url }' \
      "$path" >"$tmp" || { rm -f "$tmp"; echo "  ⚠ jq failed on $path — left unchanged" >&2; return 1; }
  else
    jq -n --arg url "$JIRA_MCP_URL" '{ mcpServers: { atlassian: { type: "sse", url: $url } } }' >"$tmp"
  fi
  mv "$tmp" "$path"
}

_mcp_merge_jira_cursor() {
  local path="$1" tmp
  tmp="$(mktemp)"
  mkdir -p "$(dirname "$path")"
  if [[ -f "$path" ]]; then
    jq --arg url "$JIRA_MCP_URL" '
      .mcpServers = (.mcpServers // {}) |
      .mcpServers.atlassian = { url: $url }' \
      "$path" >"$tmp" || { rm -f "$tmp"; echo "  ⚠ jq failed on $path — left unchanged" >&2; return 1; }
  else
    jq -n --arg url "$JIRA_MCP_URL" '{ mcpServers: { atlassian: { url: $url } } }' >"$tmp"
  fi
  mv "$tmp" "$path"
}

mcp_merge_jira() {
  local root="$1"
  _mcp_merge_jira_claude "$root/.mcp.json"        && echo "  ✓ .mcp.json — mcpServers.atlassian"
  _mcp_merge_jira_cursor "$root/.cursor/mcp.json" && echo "  ✓ .cursor/mcp.json — mcpServers.atlassian"
}

_mcp_remove_jira() {
  local path="$1" tmp
  [[ -f "$path" ]] || return 0
  jq -e '.mcpServers.atlassian' "$path" >/dev/null 2>&1 || return 0
  tmp="$(mktemp)"
  if jq 'del(.mcpServers.atlassian)' "$path" >"$tmp" 2>/dev/null; then
    mv "$tmp" "$path"
    echo "  removed mcpServers.atlassian from $path"
  else
    rm -f "$tmp"
    echo "  ⚠ jq failed on $path — left unchanged" >&2
  fi
}

mcp_remove_jira() {
  local root="$1"
  _mcp_remove_jira "$root/.mcp.json"
  _mcp_remove_jira "$root/.cursor/mcp.json"
}

# ─── Uninstall ───────────────────────────────────────────────────────────────

uninstall() {
  require_cmd jq
  local b; b="$(bar)"
  echo "$b"
  echo "  $PROG_NAME · Uninstall  v$TOOL_VERSION"
  echo ""
  echo "  Removes the jira skill and the Atlassian MCP server. Your editor's"
  echo "  OAuth session with Atlassian is managed by the editor — revoke it"
  echo "  there (or in Atlassian account settings) if you want."
  echo "$b"
  echo ""

  rm -rf "$SKILLS_DIR/jira"
  echo "  removed skills/jira"
  local dest
  for dest in "$WORKSPACE_ROOT/.claude/skills/jira" "$WORKSPACE_ROOT/.cursor/skills/jira"; do
    rm -rf "$dest"; echo "  removed ${dest#"$WORKSPACE_ROOT"/}"
  done

  echo ""
  echo "── Removing MCP registration ──"
  mcp_remove_jira "$WORKSPACE_ROOT"

  manifest_remove "jira"
  echo ""
  echo "Done. Restart your editor so it drops the Atlassian MCP server."
}

# ─── Main ────────────────────────────────────────────────────────────────────

main() {
  case "${1:-}" in
    -h | --help | help)
      echo "$PROG_NAME · Byrde Agents v$TOOL_VERSION"
      echo ""
      echo "Pins a Jira site + project, installs the jira skill, and registers"
      echo "Atlassian's Remote MCP server (OAuth handled by the editor)."
      echo ""
      echo "Usage:"
      echo "  cd /your/workspace && $0              # configure Jira project management"
      echo "  cd /your/workspace && $0 uninstall    # remove the skill + MCP server"
      exit 0
      ;;
    uninstall | remove)
      uninstall
      exit 0
      ;;
  esac

  require_cmd jq
  require_cmd python3

  print_intro

  # ── Site + project key to pin ───────────────────────────────────────────────
  local site project_key
  site="$(prompt_site)"
  project_key="$(prompt_project_key)"

  # ── Render skill ────────────────────────────────────────────────────────────
  echo ""
  echo "── Installing jira skill ──"
  ignore_skills_home
  render_skill "$JIRA_TEMPLATE" "$JIRA_OUT" "$site" "$project_key"
  sync_skill_to_editors "jira"
  manifest_add "jira"

  # ── Register the Atlassian MCP server ───────────────────────────────────────
  echo ""
  echo "── Registering Atlassian MCP ──"
  mcp_merge_jira "$WORKSPACE_ROOT"
  echo "    auth: OAuth 2.1 — the editor runs the consent flow on first use;"
  echo "          no token or secret is written to the config."

  echo ""
  if [[ -n "$site" && -n "$project_key" ]]; then
    echo "Done. Jira $site project $project_key."
  else
    echo "Done. Jira not fully pinned yet — re-run this script to set site/project."
  fi
  echo "  Verify with: .agents/scripts/doctor.sh"
  echo "  Restart your editor, then authorize Atlassian on first use (or via /mcp)."
}

main "$@"
