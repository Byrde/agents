#!/usr/bin/env bash
# Emit the GitHub MCP Authorization header on stdout, as JSON, for Claude Code's
# `headersHelper` (see lib/mcp.sh). Claude Code runs this fresh on each MCP
# connection and merges the output into the request headers — so the token is
# fetched live and NEVER written to disk.
#
# Token source, in order:
#   1. `gh auth token`                   — your existing GitHub CLI login
#   2. $GITHUB_PERSONAL_ACCESS_TOKEN     — fallback if gh is unavailable
#
# `gh` is resolved WITHOUT trusting PATH, and that is the point of gh_bin below.
# An editor launched from Finder or the Dock inherits PATH=/usr/bin:/bin:/usr/
# sbin:/sbin from launchd, which carries neither Homebrew nor nvm. A bare `gh`
# is then unresolvable, this script emits nothing, the server gets no
# Authorization header, and the editor falls back to the OAuth handshake that
# GitHub cannot complete — surfacing as "Incompatible auth server: does not
# support dynamic client registration". That message names OAuth and the real
# cause is a missing binary, so it sends you the wrong way.
#
# Set BYRDE_GH_BIN to an explicit path to override the search.
#
# For SAML-SSO orgs (e.g. enterprise), the gh login / token must be authorized
# for the org. Output shape: {"Authorization": "Bearer <token>"}.

set -euo pipefail

# Standard install locations, tried in order when PATH does not resolve gh.
GH_CANDIDATES="
/opt/homebrew/bin/gh
/usr/local/bin/gh
/usr/bin/gh
/home/linuxbrew/.linuxbrew/bin/gh
/snap/bin/gh
"

# Print the path to a usable gh, or nothing. Always exits 0 — an absent gh is a
# normal state here, because the token can still come from the environment.
gh_bin() {
  local candidate found

  if [ -n "${BYRDE_GH_BIN:-}" ]; then
    if [ -x "$BYRDE_GH_BIN" ]; then printf '%s\n' "$BYRDE_GH_BIN"; fi
    return 0
  fi

  found="$(command -v gh 2>/dev/null || true)"
  if [ -n "$found" ]; then printf '%s\n' "$found"; return 0; fi

  for candidate in $GH_CANDIDATES; do
    if [ -x "$candidate" ]; then printf '%s\n' "$candidate"; return 0; fi
  done
  return 0
}

token=""
gh="$(gh_bin)"
[ -n "$gh" ] && token="$("$gh" auth token 2>/dev/null || true)"
[ -n "$token" ] || token="${GITHUB_PERSONAL_ACCESS_TOKEN:-}"

if [ -z "$token" ]; then
  echo "gh-mcp-headers: no GitHub token — run 'gh auth login' or set GITHUB_PERSONAL_ACCESS_TOKEN" >&2
  exit 1
fi

printf '{"Authorization": "Bearer %s"}\n' "$token"
