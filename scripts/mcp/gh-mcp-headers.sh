#!/usr/bin/env bash
# Emit the GitHub MCP Authorization header on stdout, as JSON, for Claude Code's
# `headersHelper` (see lib/mcp.sh). Claude Code runs this fresh on each MCP
# connection and merges the output into the request headers — so the token is
# fetched live and NEVER written to disk.
#
# WHICH ACCOUNT, in order:
#   1. $BYRDE_GH_ACCOUNT                     — explicit override
#   2. `githubAccount` in the workspace map  — this workspace's account
#   3. the machine-active `gh` account       — the default
#
# Ranks 1 and 2 are BINDING. When a workspace names an account and no token for
# it is available, this script fails instead of falling back. GitHub is
# per-client: somebody working across several client organisations would
# otherwise get the last-switched-to client's token in every workspace, and a
# valid token for the wrong account looks exactly like success.
#
# HOW THE TOKEN IS FOUND:
#   `gh auth token`                      — your GitHub CLI login
#   $GITHUB_PERSONAL_ACCESS_TOKEN        — fallback, rank 3 only
#
# `gh` and `jq` are resolved WITHOUT trusting PATH. An editor launched from
# Finder or the Dock inherits PATH=/usr/bin:/bin:/usr/sbin:/sbin from launchd,
# which carries neither Homebrew nor nvm. A bare `gh` is then unresolvable, this
# script emits nothing, the server gets no Authorization header, and the editor
# falls back to an OAuth handshake GitHub cannot complete — surfacing as
# "Incompatible auth server: does not support dynamic client registration".
# That message names OAuth while the real cause is a missing binary.
#
# For SAML-SSO orgs, the gh login must be authorized for the org.
# Output shape: {"Authorization": "Bearer <token>"}.

set -euo pipefail

# Standard install locations, tried in order when PATH does not resolve a binary.
BIN_DIRS="/opt/homebrew/bin /usr/local/bin /usr/bin /home/linuxbrew/.linuxbrew/bin /snap/bin"

# find_bin <name> [<explicit override>] — print a usable path, or nothing.
# Always exits 0. An absent binary is a normal state that callers decide about.
find_bin() {
  local name="$1" override="${2:-}" dir found
  if [ -n "$override" ]; then
    if [ -x "$override" ]; then printf '%s\n' "$override"; fi
    return 0
  fi
  found="$(command -v "$name" 2>/dev/null || true)"
  if [ -n "$found" ]; then printf '%s\n' "$found"; return 0; fi
  for dir in $BIN_DIRS; do
    if [ -x "$dir/$name" ]; then printf '%s\n' "$dir/$name"; return 0; fi
  done
  return 0
}

# The context root is three levels above this script's directory:
#   <root>/.agents/scripts/mcp/gh-mcp-headers.sh
# `.mcp.json` records an absolute path into this workspace's own `.agents`, so
# the root resolves from the script's own location and never from the working
# directory — the editor runs this helper from a directory of its choosing.
_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONTEXT_ROOT="$(cd "$_here/../../.." 2>/dev/null && pwd || true)"

# Print this workspace's GitHub account, or nothing for the active account.
gh_account() {
  if [ -n "${BYRDE_GH_ACCOUNT:-}" ]; then
    printf '%s\n' "$BYRDE_GH_ACCOUNT"
    return 0
  fi
  local map="$CONTEXT_ROOT/.workspace.agents.json" jq_bin
  [ -n "$CONTEXT_ROOT" ] && [ -f "$map" ] || return 0
  jq_bin="$(find_bin jq "${BYRDE_JQ_BIN:-}")"
  # No jq means the map cannot be read. Degrade to the active account rather
  # than guess at JSON with a regex.
  [ -n "$jq_bin" ] || return 0
  "$jq_bin" -r '.githubAccount // empty' "$map" 2>/dev/null || true
}

gh="$(find_bin gh "${BYRDE_GH_BIN:-}")"
account="$(gh_account)"
token=""

if [ -n "$account" ]; then
  # Binding. Never hand this workspace another account's token.
  if [ -z "$gh" ]; then
    echo "gh-mcp-headers: this workspace requires the '$account' GitHub account, but gh was not found" >&2
    exit 1
  fi
  token="$("$gh" auth token --user "$account" 2>/dev/null || true)"
  if [ -z "$token" ]; then
    echo "gh-mcp-headers: no token for the '$account' GitHub account that this workspace requires." >&2
    echo "  Log that account in with 'gh auth login', or change githubAccount in .workspace.agents.json." >&2
    exit 1
  fi
else
  [ -n "$gh" ] && token="$("$gh" auth token 2>/dev/null || true)"
  [ -n "$token" ] || token="${GITHUB_PERSONAL_ACCESS_TOKEN:-}"
  if [ -z "$token" ]; then
    echo "gh-mcp-headers: no GitHub token — run 'gh auth login' or set GITHUB_PERSONAL_ACCESS_TOKEN" >&2
    exit 1
  fi
fi

printf '{"Authorization": "Bearer %s"}\n' "$token"
