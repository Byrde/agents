#!/usr/bin/env bash
# test_harness_adapters.sh — every asset lands where each harness reads it, in
# the shape it reads, and comes back out cleanly.
#
# Wiring layer: no session, no API calls, no cost. The harness paths and formats
# under test are documented in scripts/lib/harness.sh.
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/harness.sh"

LIB="$REPO_ROOT/scripts/lib/harness.sh"
HOOK="$REPO_ROOT/scripts/hooks/reinject-rules.sh"

load_lib() {
  # shellcheck source=/dev/null
  . "$LIB"
}

# A rule source in the shared format.
make_rule() {
  mkdir -p "$(dirname "$1")"
  cat >"$1" <<'EOF'
---
description: A test rule
trigger: always_on
---

# Test rule
RULE_BODY_MARKER
EOF
}

GITHUB_SPEC='{"type":"http","url":"https://example.test/mcp/","headersHelper":"/abs/helper.sh","bearerEnv":"GH_TOKEN"}'
STDIO_SPEC='{"type":"stdio","command":"/usr/bin/python3","args":["-m","srv"],"env":{"K":"v"}}'

# ─── Selection ───────────────────────────────────────────────────────────────

test_parse_accepts_names_numbers_and_all() {
  load_lib
  assert_eq "claude codex" "$(harness_parse "Codex, claude" 2>/dev/null)" "names are not normalised"
  assert_eq "cursor copilot" "$(harness_parse "2 4" 2>/dev/null)" "numbers do not index the list"
  assert_eq "$HARNESS_ALL" "$(harness_parse all)" "'all' does not select every harness"
  assert_eq "claude" "$(harness_parse "claude vim" 2>/dev/null)" "an unknown name was not dropped"
}

test_selection_prefers_env_then_map_then_default() {
  load_lib
  WORKSPACE_FILE="$SANDBOX/.workspace.agents.json"
  unset BYRDE_HARNESSES
  assert_eq "opencode" "$(harness_selected)" "with nothing chosen, only OpenCode should be installed"
  echo '{"mode":"mono","repos":[]}' >"$WORKSPACE_FILE"
  harness_save "codex antigravity"
  assert_eq "codex antigravity" "$(harness_selected)" "the saved choice is not read back"
  assert_eq "claude cursor copilot opencode" "$(harness_unselected)" "unselected is not the complement"
  assert_eq "copilot" "$(BYRDE_HARNESSES=copilot harness_selected)" "the env override does not win"
}

test_workspace_refresh_keeps_the_harness_choice() {
  command -v jq >/dev/null 2>&1 || skip "jq is not on PATH"
  AGENTS_ROOT="$REPO_ROOT"
  WORKSPACE_ROOT="$SANDBOX"; SIBLING_REPOS=()
  WORKSPACE_FILE="$SANDBOX/.workspace.agents.json"
  # shellcheck source=/dev/null
  . "$REPO_ROOT/scripts/lib/workspace.sh"
  echo '{"mode":"mono","repos":[],"harnesses":["codex"]}' >"$WORKSPACE_FILE"
  workspace_generate mono 2>/dev/null
  assert_json "$WORKSPACE_FILE" '.harnesses | join(",")' "codex" "init's refresh dropped the harness choice"
}

# ─── Rules ───────────────────────────────────────────────────────────────────

test_rules_render_in_each_harness_format() {
  load_lib
  local src="$SANDBOX/src/rules/demo.md" root="$SANDBOX/p"
  make_rule "$src"; mkdir -p "$root"
  local h
  for h in claude cursor copilot codex antigravity; do harness_rule_install "$root" "$h" "$src"; done

  assert_eq "# Test rule" "$(head -1 "$root/.claude/rules/demo.md")" \
    "Claude's copy should carry no frontmatter"
  assert_contains "$(cat "$root/.cursor/rules/demo.mdc")" "alwaysApply: true" "Cursor's rule is not always-on"
  assert_contains "$(cat "$root/.cursor/rules/demo.mdc")" "description: A test rule" "Cursor's rule lost its description"
  assert_contains "$(cat "$root/.github/instructions/demo.instructions.md")" 'applyTo: "**"' \
    "Copilot's instructions do not apply to every file"
  assert_contains "$(cat "$root/AGENTS.md")" "RULE_BODY_MARKER" "Codex's AGENTS.md lacks the rule body"
  assert_not_contains "$(cat "$root/AGENTS.md")" "trigger:" "Codex got the source frontmatter"
  # Not the checkout's own rules/, so it goes to the legacy folder, with a trigger.
  assert_contains "$(cat "$root/.agent/rules/demo.md")" "trigger: always_on" \
    "Antigravity's copy is not always-on"
}

test_antigravity_reads_the_shared_rules_in_place() {
  load_lib
  local root="$SANDBOX/p"
  make_rule "$root/.agents/rules/demo.md"
  harness_rule_install "$root" antigravity "$root/.agents/rules/demo.md"
  [ -e "$root/.agent" ] && fail "a rule Antigravity already reads was copied again"
  return 0
}

test_codex_sections_keep_the_host_text_and_do_not_grow() {
  load_lib
  # Neither Codex nor OpenCode selected, so nothing else still needs the
  # sections and removing them is what init would do.
  export BYRDE_HARNESSES="claude"
  local src="$SANDBOX/src/demo.md" root="$SANDBOX/p"
  make_rule "$src"; mkdir -p "$root"
  printf '# Host notes\n\nKeep me.\n' >"$root/AGENTS.md"
  harness_rule_install "$root" codex "$src"
  local first; first="$(cat "$root/AGENTS.md")"
  harness_rule_install "$root" codex "$src"
  assert_eq "$first" "$(cat "$root/AGENTS.md")" "re-installing changed AGENTS.md"
  harness_rule_remove "$root" codex demo
  assert_eq "$(printf '# Host notes\n\nKeep me.')" "$(cat "$root/AGENTS.md")" \
    "removing the section did not give back the host's file unchanged"
}

test_codex_removes_an_agents_md_that_was_all_ours() {
  load_lib
  # Neither Codex nor OpenCode selected, so nothing else still needs the
  # sections and removing them is what init would do.
  export BYRDE_HARNESSES="claude"
  local src="$SANDBOX/src/demo.md" root="$SANDBOX/p"
  make_rule "$src"; mkdir -p "$root"
  harness_rule_install "$root" codex "$src"
  assert_eq "AGENTS.md" "$(harness_gitignore_entries "$root" codex | grep AGENTS)" \
    "an AGENTS.md that is all generated is not ignored"
  harness_rule_remove "$root" codex demo
  assert_no_file "$root/AGENTS.md" "an emptied AGENTS.md was left behind"
}

# ─── Skills ──────────────────────────────────────────────────────────────────

test_only_claude_gets_a_skill_copy_when_agents_is_the_source() {
  load_lib
  local root="$SANDBOX/p" src
  src="$root/.agents/skills/demo"
  mkdir -p "$src"; echo "x" >"$src/SKILL.md"
  local h
  for h in $HARNESS_ALL; do harness_skill_install "$root" "$h" "$src"; done
  assert_file "$root/.claude/skills/demo/SKILL.md" "Claude Code got no copy"
  [ -e "$root/.cursor/skills" ] && fail "Cursor got a copy of a skill it reads in .agents/skills/"
  for h in $HARNESS_ALL; do harness_skill_remove "$root" "$h" demo "$src"; done
  assert_file "$src/SKILL.md" "removing the mirrors deleted the source"
  [ -e "$root/.claude/skills/demo" ] && fail "the Claude copy survived the removal"
  return 0
}

test_a_staged_skill_is_mirrored_into_agents_skills() {
  load_lib
  local root="$SANDBOX/repo" src="$SANDBOX/repo/.byrde/skills/demo"
  mkdir -p "$src"; echo "x" >"$src/SKILL.md"
  harness_skill_install "$root" codex "$src"
  assert_file "$root/.agents/skills/demo/SKILL.md" "Codex cannot see a skill staged outside .agents/skills/"
}

# ─── MCP ─────────────────────────────────────────────────────────────────────

test_mcp_renders_in_each_harness_schema() {
  command -v jq >/dev/null 2>&1 || skip "jq is not on PATH"
  load_lib
  local root="$SANDBOX/p" h
  mkdir -p "$root"
  for h in claude cursor codex copilot; do harness_mcp_put "$root" "$h" github "$GITHUB_SPEC"; done

  assert_json "$root/.mcp.json" '.mcpServers.github.headersHelper' "/abs/helper.sh" \
    "Claude Code should fetch the token with its headersHelper"
  assert_json "$root/.cursor/mcp.json" '.mcpServers.github.headers.Authorization' 'Bearer ${env:GH_TOKEN}' \
    "Cursor's header does not read the token from the environment"
  assert_json "$root/.vscode/mcp.json" '.servers.github.type' "http" "VS Code needs servers.<name>.type"
  assert_contains "$(cat "$root/.codex/config.toml")" 'bearer_token_env_var = "GH_TOKEN"' \
    "Codex does not read the token from the environment"
  assert_contains "$(cat "$root/.codex/config.toml")" '[mcp_servers.github]' "Codex has no server table"
}

test_antigravity_refuses_a_token_from_the_environment() {
  command -v jq >/dev/null 2>&1 || skip "jq is not on PATH"
  load_lib
  local root="$SANDBOX/p"
  mkdir -p "$root"
  harness_mcp_put "$root" antigravity github "$GITHUB_SPEC" 2>/dev/null
  assert_status 2 "$?" "Antigravity should report that it skipped the server"
  assert_no_file "$root/.agents/mcp_config.json" "a server Antigravity cannot authenticate was written"
  harness_mcp_put "$root" antigravity figma '{"type":"http","url":"https://f.test/mcp"}'
  assert_json "$root/.agents/mcp_config.json" '.mcpServers.figma.serverUrl' "https://f.test/mcp" \
    "Antigravity needs serverUrl, not url"
}

test_mcp_stdio_server_in_codex_toml() {
  load_lib
  local root="$SANDBOX/p"
  mkdir -p "$root"
  harness_mcp_put "$root" codex localsrv "$STDIO_SPEC"
  local toml; toml="$(cat "$root/.codex/config.toml")"
  assert_contains "$toml" 'command = "/usr/bin/python3"' "the command is missing"
  assert_contains "$toml" 'args = ["-m", "srv"]' "the args are not a TOML array"
  assert_contains "$toml" 'env = { K = "v" }' "the env is not an inline table"
  if command -v python3 >/dev/null 2>&1 && python3 -c 'import tomllib' 2>/dev/null; then
    python3 -c 'import sys,tomllib; tomllib.load(open(sys.argv[1],"rb"))' "$root/.codex/config.toml" \
      || fail "the generated config.toml does not parse"
  fi
}

test_mcp_removal_leaves_no_empty_files() {
  command -v jq >/dev/null 2>&1 || skip "jq is not on PATH"
  load_lib
  local root="$SANDBOX/p" h
  mkdir -p "$root"
  for h in claude cursor codex copilot; do harness_mcp_put "$root" "$h" github "$GITHUB_SPEC"; done
  for h in claude cursor codex copilot; do harness_mcp_remove "$root" "$h" github; done
  local f
  for f in .mcp.json .cursor/mcp.json .codex/config.toml .vscode/mcp.json; do
    assert_no_file "$root/$f" "removing the only server left $f behind"
  done
  [ -d "$root" ] || fail "pruning removed the project root itself"
}

# ─── Hooks ───────────────────────────────────────────────────────────────────

test_hooks_install_once_and_come_back_out() {
  command -v jq >/dev/null 2>&1 || skip "jq is not on PATH"
  load_lib
  local root="$SANDBOX/p" h
  mkdir -p "$root/.cursor"
  # Somebody else's hook must survive both the install and the removal.
  echo '{"version":1,"hooks":{"postToolUse":[{"command":"theirs.sh"}]}}' >"$root/.cursor/hooks.json"
  for h in cursor codex copilot; do
    harness_hooks_install "$root" "$h"
    harness_hooks_install "$root" "$h"
  done
  assert_json "$root/.cursor/hooks.json" '.hooks.postToolUse | length' "2" \
    "re-installing duplicated Cursor's hook"
  assert_json "$root/.codex/hooks.json" '.hooks.PostToolUse | length' "1" \
    "re-installing duplicated Codex's hook"
  assert_json "$root/.github/hooks/byrde-agents.json" '.hooks.postToolUse[0].type' "command" \
    "Copilot's hook is not a command hook"

  for h in cursor codex copilot; do harness_hooks_remove "$root" "$h"; done
  assert_json "$root/.cursor/hooks.json" '.hooks.postToolUse[0].command' "theirs.sh" \
    "removing ours took somebody else's hook with it"
  assert_no_file "$root/.codex/hooks.json" "an emptied Codex hooks file was left behind"
  assert_no_file "$root/.github/hooks/byrde-agents.json" "Copilot's hook file was left behind"
}

test_each_allow_hook_answers_in_its_harness_shape() {
  command -v jq >/dev/null 2>&1 || skip "jq is not on PATH"
  load_lib
  assert_eq "allow" "$(eval "$(harness_allow_cmd cursor)" | jq -r .permission)" "Cursor reads .permission"
  assert_eq "allow" "$(eval "$(harness_allow_cmd copilot)" | jq -r .permissionDecision)" \
    "Copilot reads .permissionDecision"
  assert_eq "allow" "$(eval "$(harness_allow_cmd codex)" | jq -r .hookSpecificOutput.permissionDecision)" \
    "Codex reads hookSpecificOutput.permissionDecision"
}

# fire_as <harness> — run the re-injection hook once, cadence 1, from a project
# with no .claude/rules, so it reads the shared source next to the script.
fire_as() {
  local proj="$SANDBOX/bare"
  mkdir -p "$proj"
  jq -nc --arg cwd "$proj" '{session_id: "s1", conversation_id: "s1", cwd: $cwd,
    hook_event_name: "PostToolUse", tool_name: "Read"}' \
    | (cd "$proj" && TMPDIR="$SANDBOX/tmp" BYRDE_RULES_REINJECT_EVERY=1 CLAUDE_PROJECT_DIR= \
         "$HOOK" --harness "$1" 2>/dev/null)
}

test_the_reinjection_hook_answers_each_harness_in_its_shape() {
  command -v jq >/dev/null 2>&1 || skip "jq is not on PATH"
  mkdir -p "$SANDBOX/tmp"
  local ctx
  ctx="$(fire_as cursor | jq -r '.additional_context')"
  assert_contains "$ctx" "project-rules-reinjected" "Cursor reads additional_context"
  assert_not_contains "$ctx" "trigger: always_on" "the source frontmatter leaked into the injection"
  assert_contains "$ctx" ".agents/rules/" "the other rules are not pointed at the shared source"
  assert_contains "$(fire_as copilot | jq -r '.additionalContext')" "project-rules-reinjected" \
    "Copilot reads a top-level additionalContext"
  assert_contains "$(fire_as codex | jq -r '.hookSpecificOutput.additionalContext')" \
    "project-rules-reinjected" "Codex reads hookSpecificOutput.additionalContext"
}

# ─── OpenCode ────────────────────────────────────────────────────────────────

test_opencode_mcp_uses_its_own_schema() {
  command -v jq >/dev/null 2>&1 || skip "jq is not on PATH"
  load_lib
  local root="$SANDBOX/p" cfg="$SANDBOX/p/.opencode/opencode.json"
  mkdir -p "$root/.opencode"
  echo '{"model":"x/y"}' >"$cfg"
  harness_mcp_put "$root" opencode github "$GITHUB_SPEC"
  harness_mcp_put "$root" opencode localsrv "$STDIO_SPEC"
  assert_json "$cfg" '.model' "x/y" "the host's own settings were lost"
  assert_json "$cfg" '.mcp.github.type' "remote" "a URL server is not a remote server"
  assert_json "$cfg" '.mcp.github.headers.Authorization' 'Bearer {env:GH_TOKEN}' \
    "OpenCode substitutes {env:VAR}, not \${env:VAR}"
  assert_json "$cfg" '.mcp.localsrv.command | join(" ")' "/usr/bin/python3 -m srv" \
    "a local server's command and args are one array"
  assert_json "$cfg" '.mcp.localsrv.environment.K' "v" "a local server's env goes in environment"
  harness_mcp_remove "$root" opencode github
  harness_mcp_remove "$root" opencode localsrv
  assert_json "$cfg" 'has("mcp")' "false" "an emptied mcp block was left behind"
  assert_json "$cfg" '.model' "x/y" "removal took the host's settings with it"
}

test_opencode_settings_allow_all_only_when_unset() {
  command -v jq >/dev/null 2>&1 || skip "jq is not on PATH"
  load_lib
  local root="$SANDBOX/p" cfg="$SANDBOX/p/.opencode/opencode.json"
  mkdir -p "$root"
  harness_hooks_install "$root" opencode
  harness_hooks_install "$root" opencode
  assert_json "$cfg" '.permission' "allow" "an unset permission was not opened up"
  assert_json "$root/.opencode/byrde-agents.json" '.ownsPermission' "true" \
    "a re-run forgot that the permission is ours"
  assert_file "$root/.opencode/plugins/byrde-agents.js" "the plugin was not installed"
  harness_hooks_remove "$root" opencode
  [ -e "$root/.opencode" ] && fail "removal left .opencode/ behind: $(find "$root/.opencode")"

  mkdir -p "$root/.opencode"
  echo '{"permission":{"bash":"ask"}}' >"$cfg"
  harness_hooks_install "$root" opencode
  assert_json "$cfg" '.permission.bash' "ask" "the user's own permission rules were overwritten"
  harness_hooks_remove "$root" opencode
  assert_json "$cfg" '.permission.bash' "ask" "removal took the user's permission rules"
}

test_agents_md_stays_while_codex_or_opencode_wants_it() {
  load_lib
  local src="$SANDBOX/src/demo.md" root="$SANDBOX/p"
  make_rule "$src"; mkdir -p "$root"
  export BYRDE_HARNESSES="opencode"
  harness_rule_install "$root" opencode "$src"
  # init drops Codex (unselected) — the section is OpenCode's too.
  harness_rule_remove "$root" codex demo
  assert_contains "$(cat "$root/AGENTS.md")" "RULE_BODY_MARKER" \
    "dropping Codex removed the rules OpenCode reads"
  harness_rule_purge "$root" demo
  assert_no_file "$root/AGENTS.md" "an uninstall left the shared sections behind"
}

# run_plugin <script> — run JS against the plugin under Bun (or Node).
run_plugin() {
  local dir="$SANDBOX/oc/.opencode"
  mkdir -p "$dir/plugins" "$SANDBOX/rules"
  cp "$REPO_ROOT/scripts/hooks/opencode/byrde-agents.js" "$dir/plugins/byrde-agents.mjs"
  printf -- '---\ndescription: d\n---\n\nGLOBAL_RULE_MARKER\n' >"$SANDBOX/rules/global.md"
  printf 'other\n' >"$SANDBOX/rules/development.md"
  jq -n --arg r "$SANDBOX/rules" '{rulesDir: $r, allowAll: true}' >"$dir/byrde-agents.json"
  printf '%s\n' "import plugin from \"$dir/plugins/byrde-agents.mjs\"" "$1" >"$SANDBOX/run.mjs"
  if command -v bun >/dev/null 2>&1; then
    BYRDE_RULES_REINJECT_EVERY=3 bun "$SANDBOX/run.mjs"
  else
    BYRDE_RULES_REINJECT_EVERY=3 node "$SANDBOX/run.mjs"
  fi
}

test_opencode_plugin_v1_hooks() {
  command -v jq >/dev/null 2>&1 || skip "jq is not on PATH"
  command -v bun >/dev/null 2>&1 || command -v node >/dev/null 2>&1 || skip "neither bun nor node is on PATH"
  local out
  out="$(run_plugin '
const h = await plugin.server({})
const outs = []
for (let i = 1; i <= 3; i++) { const o = { title: "", output: "tool said " + i, metadata: {} }; await h["tool.execute.after"]({ tool: "read", sessionID: "s", callID: String(i), args: {} }, o); outs.push(o.output) }
const mcp = { content: [{ type: "text", text: "x" }] }
for (let i = 0; i < 3; i++) await h["tool.execute.after"]({ tool: "mcp_x", sessionID: "m", callID: "c", args: {} }, mcp)
const perm = { status: "ask" }; await h["permission.ask"]({}, perm)
const comp = { context: [] }; await h["experimental.session.compacting"]({ sessionID: "s" }, comp)
console.log(JSON.stringify({ outs, mcp: mcp.content.length, perm: perm.status, comp: comp.context.join("") }))
')" || fail "the plugin did not run: $out"
  local first third
  first="$(printf '%s' "$out" | jq -r '.outs[0]')"; third="$(printf '%s' "$out" | jq -r '.outs[2]')"
  assert_eq "tool said 1" "$first" "the plugin injected before the cadence boundary"
  assert_contains "$third" "GLOBAL_RULE_MARKER" "the third tool result does not carry the lead rule"
  assert_contains "$third" "development.md" "the other rules are not named"
  assert_not_contains "$third" "description: d" "the rule's frontmatter leaked into the injection"
  assert_eq "2" "$(printf '%s' "$out" | jq -r '.mcp')" "an MCP tool result got no injection"
  assert_eq "allow" "$(printf '%s' "$out" | jq -r '.perm')" "permission.ask was not approved"
  assert_contains "$(printf '%s' "$out" | jq -r '.comp')" "GLOBAL_RULE_MARKER" "compaction does not carry the rules"
}

test_opencode_plugin_v2_hooks() {
  command -v jq >/dev/null 2>&1 || skip "jq is not on PATH"
  command -v bun >/dev/null 2>&1 || command -v node >/dev/null 2>&1 || skip "neither bun nor node is on PATH"
  local out
  out="$(run_plugin '
const hooks = {}
const ctx = {
  tool: { hook: async (n, f) => { hooks["tool." + n] = f } },
  permission: { hook: async (n, f) => { hooks["permission." + n] = f } },
  session: { hook: async (n, f) => { hooks["session." + n] = f } },
}
await plugin.setup(ctx)
const results = []
for (let i = 1; i <= 3; i++) { const e = { status: "completed", sessionID: "s", tool: "read", result: { content: [{ type: "text", text: "r" + i }] } }; hooks["tool.execute.after"](e); results.push(e.result.content.length) }
const asked = { effect: "ask" }; hooks["permission.evaluate"](asked)
const comp = { system: [] }; hooks["session.compaction"](comp)
console.log(JSON.stringify({ results, effect: asked.effect, comp: comp.system.map((p) => p.text).join("") }))
')" || fail "the plugin did not run: $out"
  assert_eq "[1,1,2]" "$(printf '%s' "$out" | jq -c '.results')" \
    "the rules were not appended to the third tool result only"
  assert_eq "allow" "$(printf '%s' "$out" | jq -r '.effect')" "permission evaluate was not approved"
  assert_contains "$(printf '%s' "$out" | jq -r '.comp')" "GLOBAL_RULE_MARKER" "compaction does not carry the rules"
}

# ─── init.sh end to end ──────────────────────────────────────────────────────

# A host repo with this checkout at .agents, and a private Claude user config.
make_host() {
  local host="$SANDBOX/host"
  mkdir -p "$host"
  git -C "$host" init -q
  git -C "$host" remote add origin git@github.com:acme/host.git
  rsync -a --exclude .git "$REPO_ROOT/" "$host/.agents/"
  # Its own repo, as a submodule is, so "did init dirty it" has an answer.
  git -C "$host/.agents" init -q
  git -C "$host/.agents" add -A
  git -C "$host/.agents" -c user.email=t@t -c user.name=t commit -qm fixture
  echo '{}' >"$SANDBOX/claude.json"
  echo "$host"
}

run_init() {
  (cd "$1" && shift && HOME="$SANDBOX/home" CLAUDE_USER_CONFIG="$SANDBOX/claude.json" \
     BYRDE_HARNESSES= .agents/scripts/init.sh "$@" </dev/null >/dev/null 2>&1)
}

test_init_installs_for_the_chosen_harnesses_and_drops_the_rest() {
  command -v jq >/dev/null 2>&1 || skip "jq is not on PATH"
  command -v rsync >/dev/null 2>&1 || skip "rsync is not on PATH"
  local host; host="$(make_host)"
  load_lib

  run_init "$host" --harness all || fail "init --harness all failed"
  assert_json "$host/.workspace.agents.json" '.harnesses | join(" ")' "$HARNESS_ALL" "the choice was not saved"
  assert_file "$host/.github/instructions/global.instructions.md" "Copilot got no rules"
  assert_file "$host/.codex/hooks.json" "Codex got no hooks"

  run_init "$host" --harness cursor || fail "init --harness cursor failed"
  assert_json "$host/.workspace.agents.json" '.harnesses | join(",")' "cursor" "the new choice was not saved"
  assert_file "$host/.cursor/rules/global.mdc" "Cursor lost its rules"
  assert_no_file "$host/.github/instructions/global.instructions.md" "a dropped harness kept its rules"
  assert_no_file "$host/.codex/hooks.json" "a dropped harness kept its hooks"
  assert_no_file "$host/.claude/rules/global.md" "Claude Code kept its rules after being dropped"

  # A plain re-run follows the saved choice instead of the default.
  run_init "$host" || fail "init re-run failed"
  assert_no_file "$host/.claude/rules/global.md" "a re-run ignored the saved choice"

  run_init "$host" uninstall || fail "init uninstall failed"
  assert_no_file "$host/.cursor/rules/global.mdc" "uninstall left rules behind"
  assert_no_file "$host/.cursor/hooks.json" "uninstall left hooks behind"
  assert_empty "$(git -C "$host/.agents" status --short 2>/dev/null)" "init dirtied the shared checkout"
}

run_tests
