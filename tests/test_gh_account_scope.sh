#!/usr/bin/env bash
# test_gh_account_scope.sh — the GitHub token belongs to the WORKSPACE'S account,
# not to whichever account happens to be active on the machine.
#
# Wiring layer: no session, no API calls, no cost.
#
# `gh auth token` returns the machine-active account. Somebody who works across
# several client organisations, each with its own GitHub account, therefore gets
# the last-switched-to client's token in every workspace — silently, because a
# valid token for the wrong account looks exactly like success.
#
# Resolution order: BYRDE_GH_ACCOUNT, then `githubAccount` in the workspace map,
# then the active account. The last one is the documented default, so an existing
# single-account setup keeps working untouched.
#
# The important case is #4 below. When a workspace names an account and that
# account has no token, the helper must FAIL. Falling back to the active account
# is the leak this file exists to prevent.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/harness.sh"

HEADERS_HELPER="$REPO_ROOT/scripts/mcp/gh-mcp-headers.sh"
WORKSPACE_LIB="$REPO_ROOT/scripts/lib/workspace.sh"

# A stand-in for `gh` that knows two accounts and refuses every other one, so a
# test can prove WHICH account was asked for.
fake_gh() {
  local path="$1"
  mkdir -p "$(dirname "$path")"
  cat >"$path" <<'SH'
#!/usr/bin/env bash
# gh auth token [--user LOGIN] | [-u LOGIN]
user=""
while [ $# -gt 0 ]; do
  case "$1" in
    --user|-u) user="$2"; shift 2 ;;
    *) shift ;;
  esac
done
case "$user" in
  "")            printf 'token-for-ACTIVE\n' ;;   # no --user: the active account
  client-alpha)  printf 'token-for-ALPHA\n' ;;
  client-beta)   printf 'token-for-BETA\n' ;;
  *)             echo "gh: no such account: $user" >&2; exit 1 ;;
esac
SH
  chmod +x "$path"
}

# A context root laid out the way a real one is: <root>/.agents/scripts/mcp/…,
# with the workspace map beside .agents. Echoes the helper path inside it.
fake_context_root() {
  local root="$1" account="${2:-}"
  mkdir -p "$root/.agents/scripts/mcp"
  cp "$HEADERS_HELPER" "$root/.agents/scripts/mcp/gh-mcp-headers.sh"
  chmod +x "$root/.agents/scripts/mcp/gh-mcp-headers.sh"
  if [ -n "$account" ]; then
    jq -n --arg a "$account" '{mode:"mono", contextRoot:".", repos:[], githubAccount:$a}' \
      >"$root/.workspace.agents.json"
  else
    jq -n '{mode:"mono", contextRoot:".", repos:[]}' >"$root/.workspace.agents.json"
  fi
  printf '%s\n' "$root/.agents/scripts/mcp/gh-mcp-headers.sh"
}

# ─── Resolution order ────────────────────────────────────────────────────────

test_the_override_wins() {
  local gh="$SANDBOX/bin/gh" helper out
  fake_gh "$gh"
  helper="$(fake_context_root "$SANDBOX/ws" client-beta)"
  out="$(BYRDE_GH_BIN="$gh" BYRDE_GH_ACCOUNT=client-alpha bash "$helper" 2>&1)"
  assert_contains "$out" "token-for-ALPHA" \
    "BYRDE_GH_ACCOUNT did not win over the workspace map"
}

test_the_workspace_map_picks_the_account() {
  local gh="$SANDBOX/bin/gh" helper out
  fake_gh "$gh"
  helper="$(fake_context_root "$SANDBOX/ws" client-beta)"
  out="$(BYRDE_GH_BIN="$gh" bash "$helper" 2>&1)"
  assert_contains "$out" "token-for-BETA" \
    "the helper ignored githubAccount and used the active account instead"
  assert_not_contains "$out" "token-for-ACTIVE" \
    "the wrong client's token leaked into a workspace that named an account"
}

test_no_account_anywhere_uses_the_active_one() {
  local gh="$SANDBOX/bin/gh" helper out
  fake_gh "$gh"
  helper="$(fake_context_root "$SANDBOX/ws")"
  out="$(BYRDE_GH_BIN="$gh" bash "$helper" 2>&1)"
  assert_contains "$out" "token-for-ACTIVE" \
    "the documented default changed — an existing single-account setup would break"
}

test_a_missing_map_uses_the_active_one() {
  local gh="$SANDBOX/bin/gh" helper out
  fake_gh "$gh"
  helper="$(fake_context_root "$SANDBOX/ws")"
  rm -f "$SANDBOX/ws/.workspace.agents.json"
  out="$(BYRDE_GH_BIN="$gh" bash "$helper" 2>&1)"
  assert_contains "$out" "token-for-ACTIVE" \
    "no map should degrade to the active account, not fail"
}

# ─── The leak this prevents ──────────────────────────────────────────────────

test_a_named_account_with_no_token_fails_instead_of_falling_back() {
  local gh="$SANDBOX/bin/gh" helper out status
  fake_gh "$gh"
  helper="$(fake_context_root "$SANDBOX/ws" client-gamma)"   # unknown to fake gh
  out="$(BYRDE_GH_BIN="$gh" bash "$helper" 2>&1)"
  status=$?
  assert_status 1 "$status" \
    "a workspace named an account with no token and the helper still succeeded"
  assert_not_contains "$out" "token-for-ACTIVE" \
    "FELL BACK to the active account — this is the cross-client token leak"
  assert_contains "$out" "client-gamma" \
    "the failure did not name the account it could not get a token for"
}

test_the_env_token_does_not_mask_a_named_account_failure() {
  local gh="$SANDBOX/bin/gh" helper out status
  fake_gh "$gh"
  helper="$(fake_context_root "$SANDBOX/ws" client-gamma)"
  out="$(BYRDE_GH_BIN="$gh" GITHUB_PERSONAL_ACCESS_TOKEN=pat-token bash "$helper" 2>&1)"
  status=$?
  assert_status 1 "$status" \
    "a PAT silently satisfied a workspace that asked for a specific account"
  assert_not_contains "$out" "pat-token" \
    "the PAT fallback masked a named-account failure"
}

# ─── The map must not lose the field on regeneration ─────────────────────────

test_regeneration_preserves_the_account() {
  local root="$SANDBOX/ws"
  mkdir -p "$root/.agents/scripts" "$root/repo"
  ( cd "$root/repo" && git init -q . )
  jq -n '{mode:"mono", contextRoot:".", generated:"old", repos:[
            {name:"repo", path:".", remote:"", owner:"", stack:[], purpose:"keep me"}],
          githubAccount:"client-beta"}' >"$root/.workspace.agents.json"

  ( AGENTS_ROOT="$root/.agents"; WORKSPACE_ROOT="$root/repo"; SIBLING_REPOS=()
    . "$WORKSPACE_LIB"; workspace_generate mono ) >/dev/null 2>&1

  assert_json "$root/.workspace.agents.json" '.githubAccount // "LOST"' "client-beta" \
    "re-running setup wiped githubAccount — the account pin would not survive"
  assert_json "$root/.workspace.agents.json" '.repos[0].purpose' "keep me" \
    "purpose preservation regressed"
}

test_regeneration_without_an_account_writes_no_empty_key() {
  local root="$SANDBOX/ws"
  mkdir -p "$root/.agents/scripts" "$root/repo"
  ( cd "$root/repo" && git init -q . )

  ( AGENTS_ROOT="$root/.agents"; WORKSPACE_ROOT="$root/repo"; SIBLING_REPOS=()
    . "$WORKSPACE_LIB"; workspace_generate mono ) >/dev/null 2>&1

  assert_json "$root/.workspace.agents.json" 'has("githubAccount")' "false" \
    "an absent account should stay absent, not become an empty string"
}

run_tests
