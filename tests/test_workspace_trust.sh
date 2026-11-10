#!/usr/bin/env bash
# test_workspace_trust.sh — init grants no Claude Code trust, and uninstall
# gives back only a grant that an older init made.
#
# Wiring layer: no session, no API calls, no cost.
#
# An older init set projects["<root>"].hasTrustDialogAccepted in ~/.claude.json
# so the GitHub MCP token helper could run, and recorded the grant in the
# manifest. GitHub now goes through the gh CLI, so init grants nothing. The
# revoke stays, so an uninstall still returns what the older init took.
#
# The care here is all in what it must NOT do. `~/.claude.json` holds every
# project on the machine plus the account. Losing a key there is far worse than
# a stale trust, and revoking a trust decision the human made in the dialog is
# worse still — hence the manifest marker.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/harness.sh"

TRUST_LIB="$REPO_ROOT/scripts/lib/trust.sh"
MANIFEST_LIB="$REPO_ROOT/scripts/lib/manifest.sh"
ROOT="/Users/someone/workspace/client-alpha"

# A user config with two other projects and account-level keys, so every test
# proves the writer is a merge and not a replace.
seed_config() {
  local path="$1" trust="$2"   # trust: true | false | absent
  mkdir -p "$(dirname "$path")"
  jq -n --arg r "$ROOT" --arg t "$trust" '
    {
      numStartups: 42,
      oauthAccount: { emailAddress: "someone@example.com" },
      projects: {
        "/Users/someone/other-a": { hasTrustDialogAccepted: true, history: ["keep"] },
        "/Users/someone/other-b": { hasTrustDialogAccepted: false }
      }
    }
    | if $t != "absent" then
        .projects[$r] = { hasTrustDialogAccepted: ($t == "true"), history: ["mine"] }
      else . end' >"$path"
}

# Run a trust function against an isolated config + manifest.
#
# Fails loudly when the library or the function is missing. Without this, a
# test that asserts "the config was NOT changed" passes when nothing ran at
# all — which is every one of these tests before the library exists.
run_trust() {
  local fn="$1" cfg="$2" manifest="$3"
  [ -f "$TRUST_LIB" ] || _abort "scripts/lib/trust.sh does not exist"
  ( CLAUDE_USER_CONFIG="$cfg"; MANIFEST_FILE="$manifest"
    . "$MANIFEST_LIB"
    . "$TRUST_LIB"
    command -v "$fn" >/dev/null 2>&1 || { echo "TESTBUG: $fn is not defined" >&2; exit 90; }
    "$fn" "$ROOT" ) 2>&1
  local rc=$?
  [ "$rc" = 90 ] && _abort "$fn is not defined in trust.sh"
  return 0
}

# What an older init left: the workspace trusted, and the grant recorded.
seed_old_grant() {
  local cfg="$1" mf="$2"
  seed_config "$cfg" true
  ( MANIFEST_FILE="$mf"; . "$MANIFEST_LIB"; manifest_add workspace-trust )
}

# ─── Revoking ────────────────────────────────────────────────────────────────

test_revoke_gives_back_what_init_granted() {
  local cfg="$SANDBOX/claude.json" mf="$SANDBOX/manifest.yml"
  seed_old_grant "$cfg" "$mf"
  run_trust revoke_workspace_trust "$cfg" "$mf" >/dev/null

  assert_json "$cfg" '.projects["'"$ROOT"'"].hasTrustDialogAccepted' "false" \
    "uninstall left the workspace trusted"
  assert_not_contains "$(cat "$mf" 2>/dev/null || echo)" "workspace-trust" \
    "the marker outlived the grant"
  assert_json "$cfg" '.numStartups' "42" "revoking lost an account-level key"
  assert_json "$cfg" '.projects | keys | length' "3" "a project entry was lost"
  assert_json "$cfg" '.projects["/Users/someone/other-a"].hasTrustDialogAccepted' "true" \
    "another project's trust was changed"
  assert_json "$cfg" '.projects["'"$ROOT"'"].history | join(",")' "mine" \
    "this project's own other keys were dropped"
}

test_revoke_never_rewrites_a_malformed_config() {
  local cfg="$SANDBOX/claude.json" mf="$SANDBOX/manifest.yml" out before
  ( MANIFEST_FILE="$mf"; . "$MANIFEST_LIB"; manifest_add workspace-trust )
  printf '{ this is not json' >"$cfg"
  before="$(cat "$cfg")"
  out="$(run_trust revoke_workspace_trust "$cfg" "$mf")"
  assert_eq "$before" "$(cat "$cfg")" \
    "a config that could not be parsed was overwritten anyway"
  assert_contains "$out" "could not" "the refusal was silent"
}

test_revoke_leaves_the_humans_own_trust_alone() {
  local cfg="$SANDBOX/claude.json" mf="$SANDBOX/manifest.yml"
  seed_config "$cfg" true          # trusted by the human, never by init
  : >"$mf"                          # manifest exists but records no grant
  run_trust revoke_workspace_trust "$cfg" "$mf" >/dev/null

  assert_json "$cfg" '.projects["'"$ROOT"'"].hasTrustDialogAccepted' "true" \
    "uninstall revoked a trust decision the human made in the dialog"
}

# ─── The installer actually calls it ─────────────────────────────────────────
#
# The cases above test the library in isolation, so every one of them still
# passes if init.sh never calls it — verified by deleting the call. Mirrors
# `the_installer_points_at_the_shipped_hook` in test_hook_wiring.sh.

test_the_installer_sources_the_trust_lib() {
  assert_contains "$(cat "$REPO_ROOT/scripts/init.sh")" 'lib/trust.sh' \
    "init.sh does not source lib/trust.sh, so the functions are undefined at run time"
}

test_nothing_grants_the_trust() {
  assert_not_contains "$(cat "$REPO_ROOT/scripts/init.sh" "$REPO_ROOT/scripts/lib/trust.sh")" 'grant_workspace_trust' \
    "the installer can still grant workspace trust"
}

test_uninstall_revokes_the_trust() {
  assert_contains "$(cat "$REPO_ROOT/scripts/init.sh")" 'revoke_workspace_trust "$WORKSPACE_ROOT"' \
    "init.sh uninstall never gives the trust back"
}

run_tests
