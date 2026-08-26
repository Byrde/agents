#!/usr/bin/env bash
# Byrde Agents — Claude Code workspace trust (shared lib).
#
# Claude Code ignores a project's own settings until the workspace is trusted.
# `.claude/settings.json` is skipped wholesale, so everything init writes there
# is inert, and the GitHub MCP's `headersHelper` is never run:
#
#   MCP server 'github': headersHelper not run — this workspace has no persisted
#   trust; accept the trust dialog here once interactively, or set
#   projects["<root>"].hasTrustDialogAccepted in ~/.claude.json.
#
# With no header the client falls back to OAuth, and GitHub supports no dynamic
# client registration, so the failure surfaces as an auth error while the token
# is fine. The tool names both remedies. init takes the second one, because the
# first cannot happen in a non-interactive session.
#
# WHAT THIS GRANTS. Trust is not MCP-specific — it makes Claude Code honour this
# project's settings generally. That is a real widening of what the installer
# does, so it is announced, it is recorded, and uninstall gives it back.
#
# WHAT IT WILL NOT DO. `~/.claude.json` holds every project on the machine and
# the account block. This never creates it, never rewrites it when it cannot be
# parsed, and never revokes trust it did not grant — a human who accepted the
# dialog keeps their decision through an uninstall.
#
# Source AFTER lib/manifest.sh (the grant marker lives in the manifest).
# Requires jq. Compatible with Bash 3.2 (macOS).

# Overridable so tests never touch a real config.
CLAUDE_USER_CONFIG="${CLAUDE_USER_CONFIG:-$HOME/.claude.json}"

# The manifest key recording that INIT granted the trust, not the human.
TRUST_MANIFEST_KEY="workspace-trust"

# Echo the trust state for a workspace: true | false | absent.
workspace_trust_state() {
  local root="$1"
  [[ -f "$CLAUDE_USER_CONFIG" ]] || { echo "absent"; return 0; }
  command -v jq >/dev/null 2>&1 || { echo "absent"; return 0; }
  jq -r --arg r "$root" '
    if (.projects // {}) | has($r) then
      (.projects[$r].hasTrustDialogAccepted // false) | tostring
    else "absent" end' "$CLAUDE_USER_CONFIG" 2>/dev/null || echo "absent"
}

# Merge one key into projects[<root>] of the user config. Internal.
# $1 = workspace root, $2 = true|false. Returns 1 without writing on any problem.
_trust_write() {
  local root="$1" value="$2" tmp
  if [[ ! -f "$CLAUDE_USER_CONFIG" ]]; then
    echo "  ⚠ no Claude Code user config at $CLAUDE_USER_CONFIG — skipping trust" >&2
    return 1
  fi
  if ! command -v jq >/dev/null 2>&1; then
    echo "  ⚠ jq not found — skipping workspace trust" >&2
    return 1
  fi
  # Never write to a file we could not read. A corrupt config is somebody's
  # whole Claude Code state; replacing it with our idea of it would be worse
  # than leaving the MCP server unregistered.
  if ! jq -e . "$CLAUDE_USER_CONFIG" >/dev/null 2>&1; then
    echo "  ⚠ could not parse $CLAUDE_USER_CONFIG — leaving it untouched" >&2
    return 1
  fi
  tmp="$(mktemp)"
  if ! jq --arg r "$root" --argjson v "$value" '
        .projects = (.projects // {})
        | .projects[$r] = ((.projects[$r] // {}) + { hasTrustDialogAccepted: $v })
      ' "$CLAUDE_USER_CONFIG" >"$tmp" 2>/dev/null; then
    rm -f "$tmp"
    echo "  ⚠ jq failed on $CLAUDE_USER_CONFIG — leaving it untouched" >&2
    return 1
  fi
  # Assert the shape we expected before replacing the original.
  if ! jq -e --arg r "$root" '.projects[$r].hasTrustDialogAccepted != null' \
        "$tmp" >/dev/null 2>&1; then
    rm -f "$tmp"
    echo "  ⚠ the rewritten config did not carry the trust key — leaving the original" >&2
    return 1
  fi
  mv "$tmp" "$CLAUDE_USER_CONFIG"
}

# Trust this workspace so Claude Code honours its project settings.
# Records the grant in the manifest ONLY when it changed the value, so
# revoke_workspace_trust can tell an init grant from the human's own choice.
grant_workspace_trust() {
  local root="$1" state
  state="$(workspace_trust_state "$root")"

  if [[ "$state" == "true" ]]; then
    echo "  ✓ workspace already trusted (your choice, left alone)"
    return 0
  fi

  _trust_write "$root" true || return 1

  if command -v manifest_add >/dev/null 2>&1; then
    manifest_add "$TRUST_MANIFEST_KEY"
  fi
  echo "  ✓ workspace trusted → projects[\"$root\"].hasTrustDialogAccepted in ${CLAUDE_USER_CONFIG/#$HOME/~}"
  echo "    Claude Code now honours this project's .claude/settings.json, which is what"
  echo "    lets the GitHub MCP run its token helper. Undone by 'init.sh uninstall'."
}

# Give the trust back on uninstall — only if init granted it.
revoke_workspace_trust() {
  local root="$1"
  if ! command -v manifest_has >/dev/null 2>&1 || ! manifest_has "$TRUST_MANIFEST_KEY"; then
    # Either no manifest, or the human trusted this workspace themselves.
    return 0
  fi
  _trust_write "$root" false || return 1
  manifest_remove "$TRUST_MANIFEST_KEY"
  echo "  ✓ workspace trust revoked (init granted it)"
}
