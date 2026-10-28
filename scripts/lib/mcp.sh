#!/usr/bin/env bash
# Byrde Agents — retire the GitHub MCP server (shared lib).
#
# GitHub goes through the gh CLI now (scripts/gh/gh.sh), not an MCP server.
# Older installs registered the account-wide GitHub MCP server in every harness
# and approved it in Claude Code's .claude/settings.json. This takes those
# entries back out, so an existing install does not keep a server that nothing
# drives. init.sh and the OpenCode init run it on every install and uninstall.
#
# Only OUR entry goes: a server named "github" that points at GitHub's MCP URL,
# or Codex's fenced block. A "github" server you pointed somewhere else stays,
# and so does its approval.
#
# Requires jq. Compatible with Bash 3.2 (macOS).

GITHUB_MCP_URL="https://api.githubcopilot.com/mcp/"
_MCP_SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Load the harness adapters unless the caller already did.
if ! declare -f harness_mcp_remove >/dev/null 2>&1; then
  # shellcheck source=harness.sh
  . "$_MCP_SCRIPTS_DIR/lib/harness.sh"
fi

# Is the "github" server for harness <h> the one an older init wrote?
_mcp_github_is_ours() {
  local root="$1" h="$2" file
  file="$root/$(harness_mcp_file "$h")"
  [[ -f "$file" ]] || return 1
  case "$h" in
    codex)   harness_mcp_has "$root" codex github ;;
    copilot) jq -e --arg u "$GITHUB_MCP_URL" '.servers.github.url == $u' "$file" >/dev/null 2>&1 ;;
    *)       jq -e --arg u "$GITHUB_MCP_URL" '(.mcpServers.github | .url // .serverUrl) == $u' "$file" >/dev/null 2>&1 ;;
  esac
}

# Take the github approval out of .claude/settings.json. Removes the file only
# if it becomes an empty object.
_mcp_unapprove_claude() {
  local path="$1" tmp filter
  [[ -f "$path" ]] || return 0
  jq -e '.enabledMcpjsonServers | index("github")' "$path" >/dev/null 2>&1 || return 0
  tmp="$(mktemp)"
  filter='
    .enabledMcpjsonServers = ((.enabledMcpjsonServers // []) - ["github"])
    | (if (.enabledMcpjsonServers // []) == [] then del(.enabledMcpjsonServers) else . end)
  '
  if jq "$filter" "$path" >"$tmp" 2>/dev/null; then
    if [[ "$(jq -S 'keys' "$tmp")" == "[]" ]]; then
      rm -f "$tmp" "$path"
    else
      mv "$tmp" "$path"
    fi
    echo "  removed the github approval from ${path##*/}"
  else
    rm -f "$tmp"
    echo "  ⚠ jq failed on $path — left unchanged" >&2
  fi
}

# Remove the old GitHub MCP server from every harness config under <root>.
mcp_retire_github() {
  local root="$1" h
  command -v jq >/dev/null 2>&1 || return 0
  for h in $HARNESS_ALL; do
    if _mcp_github_is_ours "$root" "$h"; then
      harness_mcp_remove "$root" "$h" github
      echo "  removed the old GitHub MCP server from $(harness_mcp_file "$h")"
    fi
  done
  # The approval goes with our server. A github server that is not ours keeps it.
  harness_mcp_has "$root" claude github || _mcp_unapprove_claude "$root/.claude/settings.json"
  return 0
}
