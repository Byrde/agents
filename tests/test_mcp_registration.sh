#!/usr/bin/env bash
# test_mcp_registration.sh — the GitHub MCP server is registered AND approved,
# and the token helper does not depend on PATH.
#
# Wiring layer: no session, no API calls, no cost.
#
# These guard the two ways the GitHub MCP dies without a sound.
#
#   1. `.mcp.json` names the server, nothing approves it, and a project-scoped
#      server that is not approved never loads. The editor then falls back to
#      OAuth and reports "Incompatible auth server: does not support dynamic
#      client registration" — which reads like a credential problem and is not.
#      `lib/mcp.sh` already documents that failure; it has to also prevent it.
#
#   2. The helper resolves `gh` through PATH. A GUI-launched editor runs with
#      PATH=/usr/bin:/bin:/usr/sbin:/sbin, Homebrew is not on it, so the helper
#      emits no header and case 1's fallback happens for a second reason.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/harness.sh"

MCP_LIB="$REPO_ROOT/scripts/lib/mcp.sh"
HEADERS_HELPER="$REPO_ROOT/scripts/mcp/gh-mcp-headers.sh"

# A stand-in for `gh` that prints a fixed token, so no test needs a real login.
fake_gh() {
  local path="$1"
  mkdir -p "$(dirname "$path")"
  cat >"$path" <<'SH'
#!/usr/bin/env bash
[ "$1" = "auth" ] && [ "$2" = "token" ] && { printf 'test-token-123\n'; exit 0; }
exit 1
SH
  chmod +x "$path"
}

# ─── The token helper must not depend on PATH ────────────────────────────────

test_helper_emits_the_header_when_gh_is_off_the_path() {
  local gh="$SANDBOX/opt/bin/gh" out status
  fake_gh "$gh"
  # The PATH a Finder-launched editor actually has. `gh` is unreachable on it.
  out="$(PATH=/usr/bin:/bin BYRDE_GH_BIN="$gh" \
         GITHUB_PERSONAL_ACCESS_TOKEN='' bash "$HEADERS_HELPER" 2>/dev/null)"
  status=$?
  assert_status 0 "$status" "the helper failed with gh off the PATH"
  assert_contains "$out" '"Authorization": "Bearer test-token-123"' \
    "the helper emitted no usable Authorization header"
}

test_helper_finds_gh_at_a_standard_location_with_a_minimal_path() {
  local real="" candidate
  for candidate in /opt/homebrew/bin/gh /usr/local/bin/gh /usr/bin/gh; do
    [ -x "$candidate" ] && { real="$candidate"; break; }
  done
  [ -n "$real" ] || skip "no gh at a standard location on this machine"
  # No override: this exercises the built-in candidate list, which is the
  # actual fix. A real token may or may not exist, so assert on the resolution
  # rather than the output — status 1 with the "no GitHub token" message means
  # gh was found and had nothing to give, which is a different failure.
  local err
  err="$(PATH=/usr/bin:/bin GITHUB_PERSONAL_ACCESS_TOKEN='' \
         bash "$HEADERS_HELPER" 2>&1 >/dev/null)"
  assert_not_contains "$err" "no GitHub token" \
    "the helper could not resolve gh at $real with a minimal PATH"
}

test_helper_still_fails_loudly_with_no_gh_and_no_token() {
  local out status
  out="$(PATH=/usr/bin:/bin BYRDE_GH_BIN="$SANDBOX/absent/gh" \
         GITHUB_PERSONAL_ACCESS_TOKEN='' bash "$HEADERS_HELPER" 2>&1)"
  status=$?
  assert_status 1 "$status" "the helper must fail when it has no token"
  assert_contains "$out" "no GitHub token" "the failure lost its message"
}

test_helper_prefers_the_env_token_when_gh_is_absent() {
  local out
  out="$(PATH=/usr/bin:/bin BYRDE_GH_BIN="$SANDBOX/absent/gh" \
         GITHUB_PERSONAL_ACCESS_TOKEN=env-token-456 bash "$HEADERS_HELPER" 2>/dev/null)"
  assert_contains "$out" '"Authorization": "Bearer env-token-456"' \
    "the GITHUB_PERSONAL_ACCESS_TOKEN fallback stopped working"
}

# ─── Registering the server must also approve it ─────────────────────────────

test_merge_writes_the_server_and_approves_it_from_nothing() {
  local root="$SANDBOX/ws"
  mkdir -p "$root"
  ( . "$MCP_LIB"; mcp_merge_github "$root" ) >/dev/null

  assert_file "$root/.mcp.json" "no .mcp.json was written"
  assert_json "$root/.mcp.json" '.mcpServers.github.type' "http" \
    "the server entry is not an http server"
  assert_file "$root/.claude/settings.json" \
    "the server was registered but never approved — it will not load"
  assert_json "$root/.claude/settings.json" \
    '.enabledMcpjsonServers | index("github") != null' "true" \
    "github is missing from enabledMcpjsonServers"
}

test_merge_preserves_existing_settings() {
  local root="$SANDBOX/ws" settings
  settings="$root/.claude/settings.json"
  mkdir -p "$root/.claude"
  jq -n '{autoMemoryEnabled: true,
          permissions: {defaultMode: "auto", allow: ["Edit","Write"]},
          enabledMcpjsonServers: ["someone-else"]}' >"$settings"

  ( . "$MCP_LIB"; mcp_merge_github "$root" ) >/dev/null

  assert_json "$settings" '.autoMemoryEnabled' "true" "autoMemoryEnabled was lost"
  assert_json "$settings" '.permissions.defaultMode' "auto" "permissions were lost"
  assert_json "$settings" '.permissions.allow | join(",")' "Edit,Write" \
    "permissions.allow was lost"
  assert_json "$settings" '.enabledMcpjsonServers | sort | join(",")' \
    "github,someone-else" "the approval did not merge with the existing list"
}

test_merge_is_idempotent() {
  local root="$SANDBOX/ws"
  mkdir -p "$root"
  ( . "$MCP_LIB"; mcp_merge_github "$root"; mcp_merge_github "$root" ) >/dev/null
  assert_json "$root/.claude/settings.json" '.enabledMcpjsonServers | length' "1" \
    "a second merge duplicated the approval"
}

test_merge_clears_a_stale_rejection() {
  local root="$SANDBOX/ws" settings
  settings="$root/.claude/settings.json"
  mkdir -p "$root/.claude"
  # A previous "no" at the trust prompt. Approving without clearing this leaves
  # the server disabled, which is the same silent failure with a new cause.
  jq -n '{disabledMcpjsonServers: ["github", "other"]}' >"$settings"

  ( . "$MCP_LIB"; mcp_merge_github "$root" ) >/dev/null

  assert_json "$settings" '.disabledMcpjsonServers | index("github") == null' "true" \
    "github stayed in disabledMcpjsonServers, so the approval is inert"
  assert_json "$settings" '.disabledMcpjsonServers | join(",")' "other" \
    "clearing the rejection removed somebody else's entry"
}

# ─── Removal has to be symmetric ─────────────────────────────────────────────

# These seed the approval directly rather than calling mcp_merge_github first.
# Routing them through the merge would make them pass whenever the merge writes
# nothing — the very defect the tests above cover — so they would go green
# against a build that approves nothing at all.

test_remove_takes_the_approval_back_out() {
  local root="$SANDBOX/ws" settings
  settings="$root/.claude/settings.json"
  mkdir -p "$root/.claude"
  jq -n '{autoMemoryEnabled: true,
          enabledMcpjsonServers: ["github", "someone-else"]}' >"$settings"

  ( . "$MCP_LIB"; mcp_remove_github "$root" ) >/dev/null

  assert_json "$settings" '.enabledMcpjsonServers | index("github") == null' "true" \
    "the approval outlived the server it approved"
  assert_json "$settings" '.enabledMcpjsonServers | join(",")' "someone-else" \
    "removal took another server's approval with it"
  assert_json "$settings" '.autoMemoryEnabled' "true" \
    "removal took an unrelated setting with it"
}

test_remove_deletes_a_settings_file_it_emptied() {
  local root="$SANDBOX/ws" settings
  settings="$root/.claude/settings.json"
  mkdir -p "$root/.claude"
  jq -n '{enabledMcpjsonServers: ["github"]}' >"$settings"

  ( . "$MCP_LIB"; mcp_remove_github "$root" ) >/dev/null

  assert_no_file "$settings" "an empty settings.json was left behind"
}

run_tests
