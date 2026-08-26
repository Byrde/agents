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
# REGISTERING THE SERVER IS TWO WRITES, NOT ONE. Claude Code treats a server
# declared in a project `.mcp.json` as untrusted until it is approved, and an
# unapproved server never loads — so the headersHelper never runs and the editor
# falls back to the very OAuth handshake the paragraph above says GitHub cannot
# complete. The failure therefore reports itself as an auth problem while the
# credential is fine. A non-interactive session cannot answer the trust prompt at
# all, so the approval has to be written here.
#
# init.sh registers the server automatically when the workspace has GitHub repos;
# setup-github-project.sh ensures it's present. All merges are idempotent.
# Requires jq. Compatible with Bash 3.2 (macOS).

GITHUB_MCP_URL="https://api.githubcopilot.com/mcp/"
# Absolute path to the headersHelper. This lib lives in scripts/lib/; the helper
# is an executable run by the editor, so it lives in scripts/mcp/ (../mcp from here).
_SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GH_MCP_HEADERS_HELPER="$_SCRIPTS_DIR/mcp/gh-mcp-headers.sh"

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

# Approve the project-scoped server in .claude/settings.json, so it actually
# loads. See the header — registration alone leaves it untrusted and inert.
#
# The named list rather than `enableAllProjectMcpServers: true`: this approves
# github and nothing else, so a server somebody adds to .mcp.json later still
# needs its own decision.
#
# A stale rejection is cleared too. `disabledMcpjsonServers` wins over the
# approval, so leaving a previous "no" in place would reproduce the same silent
# failure with a new cause. Running this is an explicit request for the server.
_mcp_approve_claude() {
  local path="$1" tmp filter
  command -v jq >/dev/null 2>&1 \
    || { echo "  ⚠ jq not found — skipping enabledMcpjsonServers" >&2; return 1; }
  mkdir -p "$(dirname "$path")"
  tmp="$(mktemp)"
  filter='
    .enabledMcpjsonServers = ((.enabledMcpjsonServers // []) + ["github"] | unique)
    | .disabledMcpjsonServers = ((.disabledMcpjsonServers // []) - ["github"])
    | (if (.disabledMcpjsonServers // []) == [] then del(.disabledMcpjsonServers) else . end)
  '
  if [[ -f "$path" ]]; then
    jq "$filter" "$path" >"$tmp" \
      || { rm -f "$tmp"; echo "  ⚠ jq failed on $path — left unchanged" >&2; return 1; }
  else
    jq -n '{ enabledMcpjsonServers: ["github"] }' >"$tmp"
  fi
  mv "$tmp" "$path"
}

# Take the approval back out (uninstall). Only strips the github entry — any
# other approved server is left alone — and removes the file only if it becomes
# an empty object.
_mcp_unapprove_claude() {
  local path="$1" tmp filter
  [[ -f "$path" ]] || return 0
  command -v jq >/dev/null 2>&1 || { echo "  ⚠ jq not found — leaving $path as-is" >&2; return 0; }
  jq -e '.enabledMcpjsonServers | index("github")' "$path" >/dev/null 2>&1 || return 0
  tmp="$(mktemp)"
  filter='
    .enabledMcpjsonServers = ((.enabledMcpjsonServers // []) - ["github"])
    | (if (.enabledMcpjsonServers // []) == [] then del(.enabledMcpjsonServers) else . end)
  '
  if jq "$filter" "$path" >"$tmp" 2>/dev/null; then
    if [[ "$(jq -S 'keys' "$tmp")" == "[]" ]]; then
      rm -f "$tmp" "$path"
      echo "  removed the github approval (and empty ${path})"
    else
      mv "$tmp" "$path"
      echo "  removed github from enabledMcpjsonServers in ${path}"
    fi
  else
    rm -f "$tmp"
    echo "  ⚠ jq failed on $path — left unchanged" >&2
  fi
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
  _mcp_approve_claude "$root/.claude/settings.json" \
    && echo "  ✓ .claude/settings.json — enabledMcpjsonServers=[github]"
  _mcp_merge_cursor "$root/.cursor/mcp.json" && echo "  ✓ .cursor/mcp.json — mcpServers.github"
}

# Remove the GitHub MCP from both editor configs under a context root.
mcp_remove_github() {
  local root="$1"
  _mcp_remove_github "$root/.mcp.json"
  _mcp_unapprove_claude "$root/.claude/settings.json"
  _mcp_remove_github "$root/.cursor/mcp.json"
}
