#!/usr/bin/env bash
# Byrde Agents — GitHub MCP registration (shared lib).
#
# The GitHub MCP server (https://api.githubcopilot.com/mcp/) is ACCOUNT-WIDE.
# GitHub's OAuth does NOT support dynamic client registration (RFC 7591), so the
# editor's auto-OAuth handshake fails ("Incompatible auth server: does not
# support dynamic client registration"). We authenticate with a token in an
# Authorization header instead — GitHub's own documented fallback.
#
# Claude Code: the token is generated LIVE on each connection by a `headersHelper`
# (gh-mcp-headers.sh → `gh auth token`), so nothing is stored on disk and there's
# no env var to set — it just works once you're logged in with gh.
# Cursor: has no headersHelper, so it gets a static `${GITHUB_PERSONAL_ACCESS_TOKEN}`
# env header — Cursor users export that var (e.g. to `$(gh auth token)`).
#
# init.sh registers the server automatically when the workspace has GitHub repos;
# setup-github-project.sh ensures it's present. All merges are idempotent.
# Requires jq. Compatible with Bash 3.2 (macOS).

GITHUB_MCP_URL="https://api.githubcopilot.com/mcp/"
# Absolute path to the headersHelper shipped alongside this lib (scripts/).
_MCP_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GH_MCP_HEADERS_HELPER="$_MCP_LIB_DIR/gh-mcp-headers.sh"

# Merge .mcpServers.github into a Claude-style config (.mcp.json). Uses
# headersHelper so the token is fetched fresh from gh on each connection.
_mcp_merge_claude() {
  local path="$1" tmp
  tmp="$(mktemp)"
  mkdir -p "$(dirname "$path")"
  if [[ -f "$path" ]]; then
    jq --arg helper "$GH_MCP_HEADERS_HELPER" '.mcpServers = (.mcpServers // {}) |
        .mcpServers.github = { type: "http", url: "https://api.githubcopilot.com/mcp/",
          headersHelper: $helper }' \
      "$path" >"$tmp" || { rm -f "$tmp"; echo "  ⚠ jq failed on $path — left unchanged" >&2; return 1; }
  else
    jq -n --arg helper "$GH_MCP_HEADERS_HELPER" '{ mcpServers: { github: {
          type: "http", url: "https://api.githubcopilot.com/mcp/", headersHelper: $helper } } }' >"$tmp"
  fi
  mv "$tmp" "$path"
}

# Merge .mcpServers.github into a Cursor-style config (.cursor/mcp.json: url+headers).
_mcp_merge_cursor() {
  local path="$1" tmp
  tmp="$(mktemp)"
  mkdir -p "$(dirname "$path")"
  if [[ -f "$path" ]]; then
    jq '.mcpServers = (.mcpServers // {}) |
        .mcpServers.github = { url: "https://api.githubcopilot.com/mcp/",
          headers: { "Authorization": "Bearer ${GITHUB_PERSONAL_ACCESS_TOKEN}" } }' \
      "$path" >"$tmp" || { rm -f "$tmp"; echo "  ⚠ jq failed on $path — left unchanged" >&2; return 1; }
  else
    jq -n '{ mcpServers: { github: { url: "https://api.githubcopilot.com/mcp/",
          headers: { "Authorization": "Bearer ${GITHUB_PERSONAL_ACCESS_TOKEN}" } } } }' >"$tmp"
  fi
  mv "$tmp" "$path"
}

_mcp_remove_github() {
  local path="$1" tmp
  [[ -f "$path" ]] || return 0
  jq -e '.mcpServers.github' "$path" >/dev/null 2>&1 || return 0
  tmp="$(mktemp)"
  if jq 'del(.mcpServers.github)' "$path" >"$tmp" 2>/dev/null; then
    mv "$tmp" "$path"
    echo "  removed mcpServers.github from ${path}"
  else
    rm -f "$tmp"
    echo "  ⚠ jq failed on $path — left unchanged" >&2
  fi
}

# Register the account-wide GitHub MCP in both editor configs under a context
# root. $1 = context root (the folder that holds .mcp.json / .cursor/).
mcp_merge_github() {
  local root="$1"
  _mcp_merge_claude "$root/.mcp.json"  && echo "  ✓ .mcp.json — mcpServers.github"
  _mcp_merge_cursor "$root/.cursor/mcp.json" && echo "  ✓ .cursor/mcp.json — mcpServers.github"
}

# Remove the GitHub MCP from both editor configs under a context root.
mcp_remove_github() {
  local root="$1"
  _mcp_remove_github "$root/.mcp.json"
  _mcp_remove_github "$root/.cursor/mcp.json"
}
