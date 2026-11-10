#!/usr/bin/env bash
# Byrde Agents — Claude Code workspace trust (shared lib).
#
# An older init set projects["<root>"].hasTrustDialogAccepted in ~/.claude.json
# so that Claude Code would run the GitHub MCP token helper, and it recorded the
# grant in the manifest. GitHub now goes through the gh CLI, so init grants no
# trust. The human accepts Claude Code's own trust dialog instead.
#
# What stays is the revoke: `init.sh uninstall` gives back a grant that an older
# init recorded, and nothing else.
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
  # than leaving the workspace untrusted.
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
