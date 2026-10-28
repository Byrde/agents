#!/usr/bin/env bash
# test_github_cli.sh — GitHub goes through the gh CLI, not an MCP server.
#
# Wiring layer: no session, no API calls, no cost.
#
# init used to register the GitHub MCP server in every harness and approve it in
# Claude Code. A re-run must take our old entries out, or every existing install
# keeps a server that nothing drives. Other servers, such as Figma, stay.
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/harness.sh"

OLD_GITHUB='{"type":"http","url":"https://api.githubcopilot.com/mcp/","headersHelper":"/old/gh-mcp-headers.sh"}'
FIGMA='{"type":"http","url":"https://mcp.figma.com/mcp"}'

# A host repo with this checkout at .agents, and a private Claude user config.
make_host() {
  local host="$SANDBOX/host" remote="${1-git@github.com:acme/host.git}"
  mkdir -p "$host"
  git -C "$host" init -q
  [ -n "$remote" ] && git -C "$host" remote add origin "$remote"
  rsync -a --exclude .git --exclude .worktrees "$REPO_ROOT/" "$host/.agents/"
  echo '{}' >"$SANDBOX/claude.json"
  echo "$host"
}

run_init() {
  (cd "$1" && shift && HOME="$SANDBOX/home" CLAUDE_USER_CONFIG="$SANDBOX/claude.json" \
     BYRDE_HARNESSES= .agents/scripts/init.sh "$@" </dev/null >/dev/null 2>&1)
}

# What an older init left behind: the GitHub server in Claude Code and Cursor,
# approved in Claude Code, next to a Figma server that setup-figma.sh owns.
seed_old_install() {
  local host="$1"
  jq -n --argjson g "$OLD_GITHUB" --argjson f "$FIGMA" '{mcpServers: {github: $g, figma: $f}}' >"$host/.mcp.json"
  mkdir -p "$host/.claude" "$host/.cursor"
  jq -n '{enabledMcpjsonServers: ["github", "figma"]}' >"$host/.claude/settings.json"
  jq -n --argjson g "$OLD_GITHUB" '{mcpServers: {github: $g}}' >"$host/.cursor/mcp.json"
}

need() { command -v jq >/dev/null 2>&1 && command -v rsync >/dev/null 2>&1 || skip "jq and rsync are needed"; }

# ─── No server ───────────────────────────────────────────────────────────────

test_init_registers_no_github_server() {
  need
  local host; host="$(make_host)"
  run_init "$host" --harness all || fail "init failed"
  local f
  for f in .mcp.json .cursor/mcp.json .vscode/mcp.json .agents/mcp_config.json; do
    if [ -f "$host/$f" ]; then
      assert_json "$host/$f" '[.mcpServers // .servers // {} | keys[] | select(. == "github")] | length' "0" \
        "init registered a GitHub MCP server in $f"
    fi
  done
  if [ -f "$host/.codex/config.toml" ]; then
    assert_not_contains "$(cat "$host/.codex/config.toml")" "mcp:github" "init registered a GitHub MCP server for Codex"
  fi
}

test_a_rerun_retires_the_old_github_server_and_keeps_the_others() {
  need
  local host; host="$(make_host)"
  seed_old_install "$host"
  run_init "$host" --harness claude,cursor || fail "init failed"
  assert_json "$host/.mcp.json" '.mcpServers | has("github")' "false" "the old GitHub server stayed in .mcp.json"
  assert_json "$host/.mcp.json" '.mcpServers | has("figma")' "true" "the Figma server was removed with it"
  assert_json "$host/.claude/settings.json" '.enabledMcpjsonServers | index("github")' "null" \
    "the old GitHub approval stayed in .claude/settings.json"
  assert_json "$host/.claude/settings.json" '.enabledMcpjsonServers | index("figma") != null' "true" \
    "the Figma approval was removed with it"
  if [ -f "$host/.cursor/mcp.json" ]; then
    assert_json "$host/.cursor/mcp.json" '.mcpServers // {} | has("github")' "false" "the old GitHub server stayed for Cursor"
  fi
}

test_a_github_server_that_is_not_ours_stays() {
  need
  local host; host="$(make_host)"
  jq -n '{mcpServers: {github: {type: "http", url: "https://ghe.example.com/mcp/"}}}' >"$host/.mcp.json"
  run_init "$host" --harness claude || fail "init failed"
  assert_json "$host/.mcp.json" '.mcpServers.github.url' "https://ghe.example.com/mcp/" \
    "init removed a GitHub server that points somewhere else, so it is not ours"
}

test_uninstall_retires_the_old_github_server() {
  need
  local host; host="$(make_host)"
  run_init "$host" --harness claude || fail "init failed"
  seed_old_install "$host"
  run_init "$host" uninstall || fail "uninstall failed"
  assert_json "$host/.mcp.json" '.mcpServers | has("github")' "false" "uninstall left the old GitHub server"
}

# ─── Trust no longer depends on GitHub ───────────────────────────────────────

test_claude_code_is_trusted_without_a_github_remote() {
  need
  local host; host="$(make_host "")"
  run_init "$host" --harness claude || fail "init failed"
  assert_json "$SANDBOX/claude.json" '[(.projects // {})[] | select(.hasTrustDialogAccepted == true)] | length' "1" \
    "Claude Code ignores .claude/settings.json (the hooks too) until the workspace is trusted"
}

# ─── The agents are told to use the wrapper ──────────────────────────────────

test_the_rule_routes_github_through_the_wrapper() {
  local rule; rule="$(cat "$REPO_ROOT/rules/github-source-control.md")"
  assert_contains "$rule" ".agents/scripts/gh/gh.sh" "the rule does not name the gh wrapper"
  assert_not_contains "$rule" "MCP" "the rule still mentions an MCP server"
}

test_github_projects_uses_the_wrapper() {
  local t; t="$(cat "$REPO_ROOT/tools/github-projects.md.template")"
  assert_contains "$t" ".agents/scripts/gh/gh.sh" "github-projects does not name the gh wrapper"
  assert_not_contains "$t" "MCP" "github-projects still mentions an MCP server"
}

run_tests
