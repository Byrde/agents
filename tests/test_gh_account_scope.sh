#!/usr/bin/env bash
# test_gh_account_scope.sh — `gh` runs as the WORKSPACE'S account, not as
# whichever account happens to be active on the machine.
#
# Wiring layer: no session, no API calls, no cost.
#
# A bare `gh` uses the machine-active account. Somebody who works across several
# client organisations, each with its own GitHub account, therefore acts as the
# last-switched-to client in every workspace — silently, because a valid token
# for the wrong account looks exactly like success.
#
# scripts/gh/gh.sh resolves the account (BYRDE_GH_ACCOUNT, then `githubAccount`
# in the workspace map, then the active account), puts that account's token in
# GH_TOKEN, and runs gh. The last rank is the documented default, so an existing
# single-account setup keeps working untouched.
#
# The important case is the leak section. When a workspace names an account and
# that account has no token, the wrapper must FAIL. Falling back to the active
# account is the leak this file exists to prevent.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/harness.sh"

GH_WRAPPER="$REPO_ROOT/scripts/gh/gh.sh"
WORKSPACE_LIB="$REPO_ROOT/scripts/lib/workspace.sh"

# A stand-in for `gh` that knows two accounts and refuses every other one, so a
# test can prove WHICH account was asked for. Any other command prints the token
# it runs with and its arguments.
fake_gh() {
  local path="$1"
  mkdir -p "$(dirname "$path")"
  cat >"$path" <<'SH'
#!/usr/bin/env bash
if [ "$1" = "auth" ] && [ "$2" = "token" ]; then
  shift 2
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
  exit 0
fi
echo "GH_TOKEN=${GH_TOKEN:-none} ARGS=$*"
[ "$1" = "fail" ] && exit 7
exit 0
SH
  chmod +x "$path"
}

# A context root laid out the way a real one is: <root>/.agents/scripts/gh/…,
# with the workspace map beside .agents. Echoes the wrapper path inside it.
fake_context_root() {
  local root="$1" account="${2:-}"
  mkdir -p "$root/.agents/scripts/gh"
  cp "$GH_WRAPPER" "$root/.agents/scripts/gh/gh.sh"
  chmod +x "$root/.agents/scripts/gh/gh.sh"
  if [ -n "$account" ]; then
    jq -n --arg a "$account" '{mode:"mono", contextRoot:".", repos:[], githubAccount:$a}' \
      >"$root/.workspace.agents.json"
  else
    jq -n '{mode:"mono", contextRoot:".", repos:[]}' >"$root/.workspace.agents.json"
  fi
  printf '%s\n' "$root/.agents/scripts/gh/gh.sh"
}

# ─── Resolution order ────────────────────────────────────────────────────────

test_the_override_wins() {
  local gh="$SANDBOX/bin/gh" wrapper out
  fake_gh "$gh"
  wrapper="$(fake_context_root "$SANDBOX/ws" client-beta)"
  out="$(cd "$SANDBOX/ws" && BYRDE_GH_BIN="$gh" BYRDE_GH_ACCOUNT=client-alpha bash "$wrapper" pr list 2>&1)"
  assert_contains "$out" "GH_TOKEN=token-for-ALPHA" \
    "BYRDE_GH_ACCOUNT did not win over the workspace map"
}

test_the_workspace_map_picks_the_account() {
  local gh="$SANDBOX/bin/gh" wrapper out
  fake_gh "$gh"
  wrapper="$(fake_context_root "$SANDBOX/ws" client-beta)"
  out="$(cd "$SANDBOX/ws" && BYRDE_GH_BIN="$gh" bash "$wrapper" pr list 2>&1)"
  assert_contains "$out" "GH_TOKEN=token-for-BETA" \
    "the wrapper ignored githubAccount and used the active account instead"
}

test_the_map_is_found_from_a_repo_below_the_context_root() {
  local gh="$SANDBOX/bin/gh" wrapper out
  fake_gh "$gh"
  wrapper="$(fake_context_root "$SANDBOX/ws" client-beta)"
  mkdir -p "$SANDBOX/ws/client-repo/src"
  out="$(cd "$SANDBOX/ws/client-repo/src" && BYRDE_GH_BIN="$gh" bash "$wrapper" pr list 2>&1)"
  assert_contains "$out" "GH_TOKEN=token-for-BETA" \
    "run from inside a workspace repo, the wrapper did not find the workspace map"
}

test_no_account_anywhere_uses_the_active_one() {
  local gh="$SANDBOX/bin/gh" wrapper out
  fake_gh "$gh"
  wrapper="$(fake_context_root "$SANDBOX/ws")"
  out="$(cd "$SANDBOX/ws" && BYRDE_GH_BIN="$gh" GH_TOKEN= bash "$wrapper" pr list 2>&1)"
  assert_contains "$out" "GH_TOKEN=none" \
    "with no account named, gh must run as the active login, untouched"
}

test_a_missing_map_uses_the_active_one() {
  local gh="$SANDBOX/bin/gh" wrapper out
  fake_gh "$gh"
  wrapper="$(fake_context_root "$SANDBOX/ws")"
  rm -f "$SANDBOX/ws/.workspace.agents.json"
  out="$(cd "$SANDBOX/ws" && BYRDE_GH_BIN="$gh" GH_TOKEN= bash "$wrapper" pr list 2>&1)"
  assert_contains "$out" "GH_TOKEN=none" \
    "no map should degrade to the active account, not fail"
}

# ─── It is gh ────────────────────────────────────────────────────────────────

test_the_arguments_and_the_exit_code_pass_through() {
  local gh="$SANDBOX/bin/gh" wrapper out status
  fake_gh "$gh"
  wrapper="$(fake_context_root "$SANDBOX/ws" client-alpha)"
  out="$(cd "$SANDBOX/ws" && BYRDE_GH_BIN="$gh" bash "$wrapper" pr create --title "a b" 2>&1)"
  assert_contains "$out" "ARGS=pr create --title a b" "the wrapper changed the arguments"
  out="$(cd "$SANDBOX/ws" && BYRDE_GH_BIN="$gh" bash "$wrapper" fail 2>&1)"
  status=$?
  assert_status 7 "$status" "the wrapper hid gh's exit code"
}

test_gh_is_found_with_a_minimal_path() {
  local gh="$SANDBOX/opt/bin/gh" wrapper out status
  fake_gh "$gh"
  wrapper="$(fake_context_root "$SANDBOX/ws" client-alpha)"
  # The PATH a Finder-launched editor has. `gh` is unreachable on it.
  out="$(cd "$SANDBOX/ws" && PATH=/usr/bin:/bin BYRDE_GH_BIN="$gh" bash "$wrapper" pr list 2>&1)"
  status=$?
  assert_status 0 "$status" "the wrapper failed with gh off the PATH: $out"
}

test_no_gh_fails_loudly() {
  local wrapper out status
  wrapper="$(fake_context_root "$SANDBOX/ws")"
  out="$(cd "$SANDBOX/ws" && BYRDE_GH_BIN="$SANDBOX/absent/gh" bash "$wrapper" pr list 2>&1)"
  status=$?
  assert_status 1 "$status" "the wrapper must fail when gh is missing"
  assert_contains "$out" "gh was not found" "the failure lost its message"
}

# ─── The leak this prevents ──────────────────────────────────────────────────

test_a_named_account_with_no_token_fails_instead_of_falling_back() {
  local gh="$SANDBOX/bin/gh" wrapper out status
  fake_gh "$gh"
  wrapper="$(fake_context_root "$SANDBOX/ws" client-gamma)"   # unknown to fake gh
  out="$(cd "$SANDBOX/ws" && BYRDE_GH_BIN="$gh" bash "$wrapper" pr list 2>&1)"
  status=$?
  assert_status 1 "$status" \
    "a workspace named an account with no token and the wrapper still ran gh"
  assert_not_contains "$out" "ARGS=" \
    "gh RAN as another account — this is the cross-client token leak"
  assert_contains "$out" "client-gamma" \
    "the failure did not name the account it could not get a token for"
}

test_an_env_token_does_not_mask_a_named_account() {
  local gh="$SANDBOX/bin/gh" wrapper out
  fake_gh "$gh"
  wrapper="$(fake_context_root "$SANDBOX/ws" client-alpha)"
  out="$(cd "$SANDBOX/ws" && BYRDE_GH_BIN="$gh" GH_TOKEN=stale-token bash "$wrapper" pr list 2>&1)"
  assert_contains "$out" "GH_TOKEN=token-for-ALPHA" \
    "a GH_TOKEN from the environment overrode the workspace's account"
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
