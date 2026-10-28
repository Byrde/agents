#!/usr/bin/env bash
# Run `gh` as this workspace's GitHub account. Use it everywhere a bare `gh`
# would go:  .agents/scripts/gh/gh.sh pr create …
#
# WHICH ACCOUNT, in order:
#   1. $BYRDE_GH_ACCOUNT                     — explicit override
#   2. `githubAccount` in the workspace map  — this workspace's account
#   3. the machine-active `gh` account       — the default
#
# Ranks 1 and 2 are BINDING. The wrapper puts that account's token in GH_TOKEN,
# and when there is no token for it, it fails instead of falling back. GitHub is
# per-client: somebody working across several client organisations would
# otherwise act as the last-switched-to client in every workspace, and a valid
# token for the wrong account looks exactly like success. Rank 3 runs gh as it
# is, so a single-account setup needs no configuration.
#
# THE WORKSPACE MAP is the nearest .workspace.agents.json at or above the
# working directory, so a run from inside one repo of a multi-repo workspace
# finds the map at the context root. When there is none, the map beside the
# .agents checkout that holds this script is used.
#
# `gh` and `jq` are resolved WITHOUT trusting PATH. An editor launched from
# Finder or the Dock inherits PATH=/usr/bin:/bin:/usr/sbin:/sbin from launchd,
# which carries neither Homebrew nor nvm.
#
# For SAML-SSO orgs, the gh login must be authorized for the org.

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

# Print the path of the workspace map, or nothing.
find_map() {
  local dir here
  dir="$(pwd -P)"
  while :; do
    if [ -f "$dir/.workspace.agents.json" ]; then printf '%s\n' "$dir/.workspace.agents.json"; return 0; fi
    [ "$dir" = "/" ] && break
    dir="$(dirname "$dir")"
  done
  # <root>/.agents/scripts/gh/gh.sh → <root>/.workspace.agents.json
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  dir="$(cd "$here/../../.." 2>/dev/null && pwd || true)"
  if [ -n "$dir" ] && [ -f "$dir/.workspace.agents.json" ]; then printf '%s\n' "$dir/.workspace.agents.json"; fi
  return 0
}

# Print this workspace's GitHub account, or nothing for the active account.
gh_account() {
  if [ -n "${BYRDE_GH_ACCOUNT:-}" ]; then
    printf '%s\n' "$BYRDE_GH_ACCOUNT"
    return 0
  fi
  local map jq_bin
  map="$(find_map)"
  [ -n "$map" ] || return 0
  jq_bin="$(find_bin jq "${BYRDE_JQ_BIN:-}")"
  # No jq means the map cannot be read. Degrade to the active account rather
  # than guess at JSON with a regex.
  [ -n "$jq_bin" ] || return 0
  "$jq_bin" -r '.githubAccount // empty' "$map" 2>/dev/null || true
}

gh="$(find_bin gh "${BYRDE_GH_BIN:-}")"
if [ -z "$gh" ]; then
  echo "gh.sh: gh was not found. Install the GitHub CLI, then run 'gh auth login'." >&2
  exit 1
fi

account="$(gh_account)"
if [ -n "$account" ]; then
  # Binding. Never run this workspace as another account.
  token="$(env -u GH_TOKEN -u GITHUB_TOKEN "$gh" auth token --user "$account" 2>/dev/null || true)"
  if [ -z "$token" ]; then
    echo "gh.sh: no token for the '$account' GitHub account that this workspace requires." >&2
    echo "  Log that account in with 'gh auth login', or change githubAccount in .workspace.agents.json." >&2
    exit 1
  fi
  export GH_TOKEN="$token"
fi

exec "$gh" "$@"
