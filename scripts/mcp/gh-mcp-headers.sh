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
# For SAML-SSO orgs (e.g. enterprise), the gh login / token must be authorized
# for the org. Output shape: {"Authorization": "Bearer <token>"}.

set -euo pipefail

token="$(gh auth token 2>/dev/null || true)"
[ -n "$token" ] || token="${GITHUB_PERSONAL_ACCESS_TOKEN:-}"

if [ -z "$token" ]; then
  echo "gh-mcp-headers: no GitHub token — run 'gh auth login' or set GITHUB_PERSONAL_ACCESS_TOKEN" >&2
  exit 1
fi

printf '{"Authorization": "Bearer %s"}\n' "$token"
