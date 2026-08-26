#!/usr/bin/env bash
# test_workspace_trust.sh — init grants this workspace Claude Code's trust, and
# uninstall gives back only what init took.
#
# Wiring layer: no session, no API calls, no cost.
#
# Claude Code ignores project settings until a workspace is trusted, and the
# GitHub MCP's headersHelper is one of the things it therefore never runs:
#
#   MCP server 'github': headersHelper not run — this workspace has no persisted
#   trust; accept the trust dialog here once interactively, or set
#   projects["<root>"].hasTrustDialogAccepted in ~/.claude.json.
#
# The tool names both remedies, so the installer takes the second one.
#
# The care here is all in what it must NOT do. `~/.claude.json` holds every
# project on the machine plus the account. Losing a key there is far worse than
# an unregistered MCP server, and revoking a trust decision the human made in
# the dialog is worse still — hence the manifest marker.
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

# ─── Granting ────────────────────────────────────────────────────────────────

test_grant_trusts_an_untrusted_workspace() {
  local cfg="$SANDBOX/claude.json" mf="$SANDBOX/manifest.yml"
  seed_config "$cfg" false
  run_trust grant_workspace_trust "$cfg" "$mf" >/dev/null

  assert_json "$cfg" '.projects["'"$ROOT"'"].hasTrustDialogAccepted' "true" \
    "the workspace was not trusted"
}

test_grant_records_that_init_did_it() {
  local cfg="$SANDBOX/claude.json" mf="$SANDBOX/manifest.yml"
  seed_config "$cfg" false
  run_trust grant_workspace_trust "$cfg" "$mf" >/dev/null

  assert_file "$mf" "no manifest was written"
  assert_contains "$(cat "$mf")" "workspace-trust" \
    "init granted trust without recording it, so uninstall cannot give it back"
}

test_grant_does_not_claim_credit_for_the_humans_choice() {
  local cfg="$SANDBOX/claude.json" mf="$SANDBOX/manifest.yml"
  seed_config "$cfg" true          # the human already accepted the dialog
  run_trust grant_workspace_trust "$cfg" "$mf" >/dev/null

  assert_json "$cfg" '.projects["'"$ROOT"'"].hasTrustDialogAccepted' "true" \
    "already-trusted must stay trusted"
  if [ -f "$mf" ]; then
    assert_not_contains "$(cat "$mf")" "workspace-trust" \
      "init claimed a grant it did not make — uninstall would revoke the human's choice"
  fi
}

test_grant_preserves_every_other_key() {
  local cfg="$SANDBOX/claude.json" mf="$SANDBOX/manifest.yml"
  seed_config "$cfg" false
  run_trust grant_workspace_trust "$cfg" "$mf" >/dev/null

  assert_json "$cfg" '.numStartups' "42" "an account-level key was lost"
  assert_json "$cfg" '.oauthAccount.emailAddress' "someone@example.com" \
    "the account block was lost"
  assert_json "$cfg" '.projects | keys | length' "3" "a project entry was lost"
  assert_json "$cfg" '.projects["/Users/someone/other-a"].history | join(",")' "keep" \
    "another project's history was lost"
  assert_json "$cfg" '.projects["/Users/someone/other-b"].hasTrustDialogAccepted' "false" \
    "another project's trust was changed"
  assert_json "$cfg" '.projects["'"$ROOT"'"].history | join(",")' "mine" \
    "this project's own other keys were dropped"
}

# ─── Refusing to act on what it cannot read ──────────────────────────────────

test_a_missing_config_is_left_missing() {
  local cfg="$SANDBOX/absent.json" mf="$SANDBOX/manifest.yml" out
  out="$(run_trust grant_workspace_trust "$cfg" "$mf")"
  assert_no_file "$cfg" "the installer invented a user config"
  assert_contains "$out" "no Claude Code user config" "it did not say why it skipped"
}

test_a_malformed_config_is_never_rewritten() {
  local cfg="$SANDBOX/claude.json" mf="$SANDBOX/manifest.yml" out before
  printf '{ this is not json' >"$cfg"
  before="$(cat "$cfg")"
  out="$(run_trust grant_workspace_trust "$cfg" "$mf")"
  assert_eq "$before" "$(cat "$cfg")" \
    "a config that could not be parsed was overwritten anyway"
  assert_contains "$out" "could not" "the refusal was silent"
}

# ─── Revoking ────────────────────────────────────────────────────────────────

test_revoke_gives_back_what_init_granted() {
  local cfg="$SANDBOX/claude.json" mf="$SANDBOX/manifest.yml"
  seed_config "$cfg" false
  run_trust grant_workspace_trust "$cfg" "$mf" >/dev/null
  run_trust revoke_workspace_trust "$cfg" "$mf" >/dev/null

  assert_json "$cfg" '.projects["'"$ROOT"'"].hasTrustDialogAccepted' "false" \
    "uninstall left the workspace trusted"
  assert_not_contains "$(cat "$mf" 2>/dev/null || echo)" "workspace-trust" \
    "the marker outlived the grant"
  assert_json "$cfg" '.numStartups' "42" "revoking lost an account-level key"
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

test_the_installer_grants_before_registering_the_mcp() {
  local init="$REPO_ROOT/scripts/init.sh" grant merge
  assert_contains "$(cat "$init")" 'grant_workspace_trust "$WORKSPACE_ROOT"' \
    "init.sh never grants workspace trust"
  grant="$(grep -n 'grant_workspace_trust "\$WORKSPACE_ROOT"' "$init" | head -1 | cut -d: -f1)"
  merge="$(grep -n 'mcp_merge_github "\$WORKSPACE_ROOT"' "$init" | head -1 | cut -d: -f1)"
  [ -n "$grant" ] && [ -n "$merge" ] || fail "could not locate both call sites in init.sh"
  # Granting after the merge leaves the approval inert for that run and fires
  # mcp.sh's untrusted warning on a fresh install.
  [ "$grant" -lt "$merge" ] || \
    fail "init.sh grants trust AFTER registering the MCP (grant line $grant, merge line $merge)"
}

test_uninstall_revokes_the_trust() {
  assert_contains "$(cat "$REPO_ROOT/scripts/init.sh")" 'revoke_workspace_trust "$WORKSPACE_ROOT"' \
    "init.sh uninstall never gives the trust back"
}

run_tests
