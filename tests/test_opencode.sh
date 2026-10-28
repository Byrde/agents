#!/usr/bin/env bash
# test_opencode.sh — scripts/opencode/: the installer, the evaluation, the
# Fuel iX setup and the plugin, offline. Every API answer comes from a fixture.
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/harness.sh"

need() {
  local c
  for c in "$@"; do command -v "$c" >/dev/null 2>&1 || skip "$c is not on PATH"; done
}

# A host repo with this checkout at .agents.
make_host() {
  local host="$SANDBOX/host"
  mkdir -p "$host"
  git -C "$host" init -q
  git -C "$host" remote add origin git@github.com:acme/host.git
  rsync -a --exclude .git --exclude .worktrees "$REPO_ROOT/" "$host/.agents/"
  echo "$host"
}

# OpenCode's /api/model answer. $1: "builtin" (only OpenCode's own provider),
# "fuelix" (plus Fuel iX), "zen-copy" (Fuel iX, and a free Zen copy of flash), or
# "zen-weak" (Fuel iX, and a free Zen model that is well below Opus).
write_models() {
  jq -n --arg kind "$1" '
    def m($p; $id; $variants; $cost): {providerID: $p, id: $id, modelID: $id,
      capabilities: {tools: true, input: ["text"], output: ["text"]},
      variants: [$variants[] | {id: .}], limit: {context: 200000}, cost: $cost,
      status: "active", enabled: true, settings: {apiKey: "SECRET-MUST-NOT-LEAK"}};
    [m("opencode"; "big-pickle"; []; [{input: 0, output: 0}])]
    + (if $kind == "builtin" then [] else [
        m("fuelix-anthropic"; "claude-opus-5-5"; ["low", "high", "max"]; []),
        m("fuelix"; "gemini-3.8-flash"; []; [])] end)
    + (if $kind == "zen-copy" then [m("opencode"; "gemini-3.8-flash"; []; [{input: 0, output: 0}])] else [] end)
    + (if $kind == "zen-weak" then [m("opencode"; "glm-5.3-flash"; []; [{input: 0, output: 0}])] else [] end)
  ' >"$SANDBOX/models-$1.json"
  echo "$SANDBOX/models-$1.json"
}

# Artificial Analysis: Opus is strong and dear, Flash is weaker, cheap and fast,
# and 100 filler entries give the percentiles a realistic population. Opus at max effort is
# one point better than at high, but thinks for 400 s instead of 15 s.
write_aa() {
  jq -n '
    def e($slug; $name; $creator; $score; $price; $speed; $ttfa): {slug: $slug, name: $name,
      model_creator: {slug: $creator}, release_date: "2026-01-01",
      evaluations: {artificial_analysis_intelligence_index: $score, artificial_analysis_coding_index: $score,
        gpqa: ($score / 100), hle: ($score / 100), aime_25: ($score / 100), livecodebench: ($score / 100),
        scicode: ($score / 100), ifbench: ($score / 100), lcr: ($score / 100),
        terminalbench_v4_0: ($score / 100), tau2: ($score / 100)},
      pricing: {price_1m_blended_3_to_1: $price, price_1m_input_tokens: $price, price_1m_output_tokens: ($price * 4)},
      median_output_tokens_per_second: $speed, median_time_to_first_token_seconds: $ttfa,
      median_time_to_first_answer_token: $ttfa};
    {data: ([
      e("claude-opus-5-5"; "Claude Opus 5.5 (Max)"; "anthropic"; 91; 30; 50; 400),
      e("claude-opus-5-5-high"; "claude-opus-5-5-high"; "anthropic"; 90; 30; 50; 15),
      e("claude-opus-5-5-low"; "claude-opus-5-5-low"; "anthropic"; 80; 30; 60; 2),
      e("glm-5-3-flash"; "glm-5-3-flash"; "zai"; 70; 1; 150; 5),
      e("gemini-3-8-flash"; "gemini-3-8-flash"; "google"; 60; 0.5; 300; 1)]
      + [range(0; 100) as $i | e("filler-\($i)"; "filler-\($i)"; "x"; (40 + ($i % 37)); (1 + ($i % 30)); (40 + ($i % 50) * 4); (1 + ($i % 20)))])}
  ' >"$SANDBOX/aa.json"
  echo "$SANDBOX/aa.json"
}

# run_init <host> <models-file> [args…] — the installer, offline.
run_init() {
  local host="$1" models="$2"
  shift 2
  (cd "$host" && BYRDE_OC_MODELS_FILE="$models" BYRDE_AA_FILE="${AA_FILE:-}" \
     BYRDE_CATALOG_FILE="$SANDBOX/catalog.json" ARTIFICIAL_ANALYSIS_API_KEY= \
     .agents/scripts/opencode/init.sh "$@" </dev/null)
}

setup() {
  need jq python3 git rsync
  echo '{}' >"$SANDBOX/catalog.json"
  HOST="$(make_host)"
}

agent_model() {
  sed -n 's/^model: "\(.*\)"$/\1/p' "$HOST/.opencode/agents/$1.md"
}

# ─── Install ─────────────────────────────────────────────────────────────────

test_a_bare_opencode_session_gives_agents_that_inherit() {
  setup
  local out
  out="$(run_init "$HOST" "$(write_models builtin)" 2>&1)" || fail "init failed: $out"
  assert_contains "$out" "mode: inherit" "init did not report the inherit mode"
  local s
  for s in plan develop debug quick-edit docs; do
    assert_file "$HOST/.opencode/agents/$s.md" "no agent for the $s skill"
    assert_contains "$(cat "$HOST/.opencode/agents/$s.md")" "mode: all" "the $s agent is not usable both ways"
    assert_empty "$(agent_model "$s")" "the $s agent is pinned although nothing was scored"
  done
  assert_not_contains "$(cat "$HOST/.opencode/agents/develop.md")" "# Develop" \
    "the agent carries a body, which replaces OpenCode's default prompt"
}

test_rules_permissions_mcp_plugin_and_memory_are_installed() {
  setup
  run_init "$HOST" "$(write_models builtin)" >/dev/null 2>&1 || fail "init failed"
  assert_contains "$(cat "$HOST/AGENTS.md")" "<!-- byrde-agents:opencode-rule global -->" "AGENTS.md has no global rule"
  assert_not_contains "$(cat "$HOST/AGENTS.md")" "trigger: always_on" "the rule frontmatter leaked into AGENTS.md"
  local cfg="$HOST/.opencode/opencode.json"
  assert_json "$cfg" '.permissions[0] | "\(.action) \(.resource) \(.effect)"' "* * allow" "allow-all is not the first rule"
  assert_json "$cfg" '[.permissions[] | select(.action == "skill" and .effect == "deny") | .resource] | index("develop") != null' \
    "true" "the develop skill is still offered as a skill"
  assert_json "$cfg" '.mcp.servers.github.type' "remote" "the GitHub MCP server is missing"
  assert_json "$cfg" '.mcp.servers.github.oauth' "false" \
    "without oauth: false, a missing token makes OpenCode hang waiting for OAuth"
  assert_json "$cfg" '.mcp.servers.github.headers.Authorization' 'Bearer {env:GITHUB_PERSONAL_ACCESS_TOKEN}' \
    "the GitHub token is not read from the environment"
  assert_file "$HOST/.opencode/plugins/byrde-agents.js" "the plugin was not installed"
  assert_json "$HOST/.opencode/byrde-agents.json" '.memoryDir' "$(cd "$HOST" && pwd)/memory" "the plugin does not know where memory is"
  [ -d "$HOST/memory" ] || fail "memory/ was not created"
  assert_file "$HOST/.workspace.agents.json" "no workspace map"
  local gi; gi="$(cat "$HOST/.gitignore")"
  assert_contains "$gi" ".opencode/agents/develop.md" "the generated agents are not ignored"
  assert_not_contains "$gi" "memory" "memory/ is ignored, but it is shared"
}

test_a_rerun_changes_nothing() {
  setup
  local models; models="$(write_models builtin)"
  run_init "$HOST" "$models" >/dev/null 2>&1 || fail "init failed"
  local cfg agents gi
  cfg="$(cat "$HOST/.opencode/opencode.json")"; agents="$(cat "$HOST/AGENTS.md")"; gi="$(cat "$HOST/.gitignore")"
  run_init "$HOST" "$models" >/dev/null 2>&1 || fail "the re-run failed"
  assert_eq "$cfg" "$(cat "$HOST/.opencode/opencode.json")" "a re-run changed opencode.json"
  assert_eq "$agents" "$(cat "$HOST/AGENTS.md")" "a re-run changed AGENTS.md"
  assert_eq "$gi" "$(cat "$HOST/.gitignore")" "a re-run changed .gitignore"
}

# ─── Evaluation ──────────────────────────────────────────────────────────────

test_configured_providers_are_scored_per_skill() {
  setup
  local out
  out="$(AA_FILE="$(write_aa)" run_init "$HOST" "$(write_models fuelix)" 2>&1)" || fail "init failed: $out"
  assert_contains "$out" "mode: scored" "the models were not scored"
  assert_eq "fuelix-anthropic/claude-opus-5-5#high" "$(agent_model plan)" "plan is not on the strongest model"
  assert_eq "fuelix-anthropic/claude-opus-5-5#high" "$(agent_model develop)" "develop is not on the strongest model"
  assert_eq "fuelix/gemini-3.8-flash" "$(agent_model quick-edit)" "quick-edit is not on the cheap, fast model"
  assert_not_contains "$(cat "$HOST/.opencode/.byrde/models.json")" "SECRET-MUST-NOT-LEAK" \
    "provider settings were written to the cache"
  assert_contains "$out" "Artificial Analysis" "the benchmark data is not credited"
}

test_a_higher_effort_must_earn_its_cost() {
  setup
  AA_FILE="$(write_aa)" run_init "$HOST" "$(write_models fuelix)" >/dev/null 2>&1 || fail "init failed"
  assert_eq "fuelix-anthropic/claude-opus-5-5#high" "$(agent_model plan)" \
    "max effort won on one point of quality, at about 25 times the thinking"
}

test_a_free_model_well_below_the_best_does_not_win_on_price() {
  setup
  AA_FILE="$(write_aa)" run_init "$HOST" "$(write_models zen-weak)" >/dev/null 2>&1 || fail "init failed"
  assert_eq "fuelix-anthropic/claude-opus-5-5#high" "$(agent_model develop)" \
    "a free model far below the best quality won develop on price"
}

test_the_report_ranks_the_top_three_with_their_cost() {
  setup
  local out
  out="$(AA_FILE="$(write_aa)" run_init "$HOST" "$(write_models fuelix)" 2>&1)" || fail "init failed: $out"
  local block; block="$(printf '%s\n' "$out" | sed -n '/^  plan /,/^  [a-z]/p')"
  assert_contains "$block" "1. fuelix-anthropic/claude-opus-5-5#high" "the pick is not ranked first"
  assert_contains "$block" "2. " "the report does not show a second candidate"
  assert_contains "$block" "3. " "the report does not show a third candidate"
  assert_contains "$block" "/answer" "the report does not show the estimated cost per answer"
  assert_contains "$block" "quality" "the report does not show the quality score"
}

test_a_free_zen_copy_wins_on_cost_once_a_provider_is_configured() {
  setup
  AA_FILE="$(write_aa)" run_init "$HOST" "$(write_models zen-copy)" >/dev/null 2>&1 || fail "init failed"
  assert_eq "opencode/gemini-3.8-flash" "$(agent_model quick-edit)" "the free copy did not beat the paid one on cost"
}

test_no_benchmark_data_means_inherit() {
  setup
  local out
  out="$(run_init "$HOST" "$(write_models fuelix)" 2>&1)" || fail "init failed: $out"
  assert_contains "$out" "ARTIFICIAL_ANALYSIS_API_KEY" "init does not say why nothing was scored"
  assert_empty "$(agent_model develop)" "an agent is pinned without benchmark data"
}

test_evaluate_follows_a_provider_change() {
  setup
  local aa; aa="$(write_aa)"
  AA_FILE="$aa" run_init "$HOST" "$(write_models fuelix)" >/dev/null 2>&1 || fail "init failed"
  assert_eq "fuelix-anthropic/claude-opus-5-5#high" "$(agent_model develop)" "develop is not pinned"
  local out
  out="$(AA_FILE="$aa" run_init "$HOST" "$(write_models builtin)" evaluate 2>&1)" || fail "evaluate failed: $out"
  assert_empty "$(agent_model develop)" "the agent kept a model whose provider is gone"
  assert_contains "$out" "(was fuelix-anthropic/claude-opus-5-5#high)" "the change is not reported"
}

# ─── Ownership and uninstall ─────────────────────────────────────────────────

test_the_users_own_files_and_settings_survive() {
  setup
  mkdir -p "$HOST/.opencode/agents"
  printf -- '---\ndescription: mine\n---\nMY_PLAN_AGENT\n' >"$HOST/.opencode/agents/plan.md"
  jq -n '{model: "x/y", permissions: [{action: "shell", resource: "rm *", effect: "ask"}]}' >"$HOST/.opencode/opencode.json"
  printf '# Host notes\n\nKeep me.\n' >"$HOST/AGENTS.md"

  run_init "$HOST" "$(write_models builtin)" >/dev/null 2>&1 || fail "init failed"
  assert_contains "$(cat "$HOST/.opencode/agents/plan.md")" "MY_PLAN_AGENT" "init overwrote the user's own agent"
  assert_json "$HOST/.opencode/opencode.json" '.model' "x/y" "init dropped the user's settings"
  assert_json "$HOST/.opencode/opencode.json" '[.permissions[] | select(.action == "shell")] | length' "1" \
    "init dropped the user's permission rule"

  run_init "$HOST" "$(write_models builtin)" uninstall >/dev/null 2>&1 || fail "uninstall failed"
  assert_contains "$(cat "$HOST/.opencode/agents/plan.md")" "MY_PLAN_AGENT" "uninstall removed the user's own agent"
  assert_no_file "$HOST/.opencode/agents/develop.md" "uninstall left a generated agent"
  assert_no_file "$HOST/.opencode/plugins/byrde-agents.js" "uninstall left the plugin"
  assert_json "$HOST/.opencode/opencode.json" '.' \
    "$(jq '.' <<<'{"model":"x/y","permissions":[{"action":"shell","resource":"rm *","effect":"ask"}],"$schema":"https://opencode.ai/config.json"}')" \
    "uninstall did not give back the user's settings"
  assert_eq "$(printf '# Host notes\n\nKeep me.')" "$(cat "$HOST/AGENTS.md")" "uninstall did not give back AGENTS.md"
  assert_not_contains "$(cat "$HOST/.gitignore")" "byrde-agents opencode" "uninstall left the .gitignore block"
}

test_uninstall_of_a_fresh_install_leaves_nothing_behind() {
  setup
  run_init "$HOST" "$(write_models builtin)" >/dev/null 2>&1 || fail "init failed"
  run_init "$HOST" "$(write_models builtin)" uninstall >/dev/null 2>&1 || fail "uninstall failed"
  [ -e "$HOST/.opencode" ] && fail "uninstall left .opencode/: $(find "$HOST/.opencode")"
  assert_no_file "$HOST/AGENTS.md" "uninstall left an AGENTS.md"
  assert_no_file "$HOST/.workspace.agents.json" "uninstall left the workspace map"
  assert_no_file "$HOST/.gitignore" "uninstall left an empty .gitignore"
  [ -d "$HOST/memory" ] || fail "uninstall removed memory/, which is the team's"
}

# ─── Fuel iX ─────────────────────────────────────────────────────────────────

run_fuelix() {
  (cd "$HOST" && BYRDE_FUELIX_MODELS_FILE="$SANDBOX/fuelix.json" FUELIX_API_KEY=k \
     BYRDE_OC_MODELS_FILE="$SANDBOX/models-builtin.json" BYRDE_CATALOG_FILE="$SANDBOX/catalog.json" \
     .agents/scripts/opencode/setup-fuelix.sh "$@" </dev/null)
}

test_fuelix_models_go_to_the_provider_for_their_api() {
  setup
  jq -n '{data: [{id: "claude-opus-5-5"}, {id: "gpt-6.1-sol"}, {id: "o4-mini"}, {id: "gemini-3.8-flash"}, {id: "dall-e-3"}]}' \
    >"$SANDBOX/fuelix.json"
  write_models builtin >/dev/null
  local out cfg="$HOST/.opencode/opencode.json"
  out="$(run_fuelix --models claude-opus-5-5,gpt-6.1-sol,o4-mini,gemini-3.8-flash,dall-e-3,nope 2>&1)" \
    || fail "setup-fuelix failed: $out"
  assert_json "$cfg" '.providers["fuelix-anthropic"].models | keys | join(",")' "claude-opus-5-5" "Claude is not on the Anthropic API"
  assert_json "$cfg" '.providers["fuelix-anthropic"].headers.Authorization' 'Bearer {env:FUELIX_API_KEY}' \
    "the Anthropic provider does not send the key as a bearer token"
  assert_json "$cfg" '.providers["fuelix-openai"].models | keys | join(",")' "gpt-6.1-sol,o4-mini" "GPT is not on the Responses API"
  assert_json "$cfg" '.providers.fuelix.models | keys | join(",")' "gemini-3.8-flash" "the rest is not on Chat Completions"
  assert_json "$cfg" '.providers.fuelix.package' "@ai-sdk/openai-compatible" "the Chat Completions provider has the wrong package"
  assert_contains "$out" "'nope'" "an unknown model was not reported"
  assert_not_contains "$(cat "$cfg")" "dall-e-3" "an image model was offered as an agent model"
  assert_not_contains "$(cat "$cfg")" '"k"' "the API key was written to disk"
}

test_fuelix_rerun_replaces_the_choice_and_reevaluates() {
  setup
  jq -n '{data: [{id: "claude-opus-5-5"}, {id: "gemini-3.8-flash"}]}' >"$SANDBOX/fuelix.json"
  run_init "$HOST" "$(write_models builtin)" >/dev/null 2>&1 || fail "init failed"
  run_fuelix --models claude-opus-5-5,gemini-3.8-flash >/dev/null 2>&1 || fail "setup-fuelix failed"
  local out
  out="$(run_fuelix --models 2 2>&1)" || fail "the re-run failed: $out"
  local cfg="$HOST/.opencode/opencode.json"
  assert_json "$cfg" '.providers | has("fuelix-anthropic")' "false" "a dropped model's provider was kept"
  assert_json "$cfg" '.providers.fuelix.models | keys | join(",")' "gemini-3.8-flash" "a number did not pick the model"
  assert_json "$cfg" '.permissions[0].effect' "allow" "setup-fuelix lost init's settings"
  assert_contains "$out" "Re-score the models" "setup-fuelix did not re-run the evaluation"

  run_fuelix uninstall >/dev/null 2>&1 || fail "uninstall failed"
  assert_json "$cfg" 'has("providers")' "false" "uninstall left the Fuel iX providers"
}

# ─── Plugin ──────────────────────────────────────────────────────────────────

test_the_plugin_adds_the_skill_memory_and_reinjected_rules() {
  need jq
  command -v bun >/dev/null 2>&1 || command -v node >/dev/null 2>&1 || skip "neither bun nor node is on PATH"
  local dir="$SANDBOX/p/.opencode"
  mkdir -p "$dir/plugins" "$SANDBOX/rules" "$SANDBOX/skills/develop" "$SANDBOX/memory"
  cp "$REPO_ROOT/scripts/opencode/plugin/byrde-agents.js" "$dir/plugins/byrde-agents.mjs"
  printf -- '---\ndescription: d\n---\n\nGLOBAL_RULE_MARKER\n' >"$SANDBOX/rules/global.md"
  printf 'other\n' >"$SANDBOX/rules/development.md"
  printf -- '---\nname: develop\ncategory: practice\n---\n\nDEVELOP_METHOD_MARKER\n' >"$SANDBOX/skills/develop/SKILL.md"
  printf -- '- [A fact](a.md) — MEMORY_INDEX_MARKER\n' >"$SANDBOX/memory/MEMORY.md"
  jq -n --arg r "$SANDBOX/rules" --arg s "$SANDBOX/skills" --arg m "$SANDBOX/memory" \
    '{rulesDir: $r, skillsDir: $s, memoryDir: $m, generated: [".opencode/agents/develop.md"]}' >"$dir/byrde-agents.json"
  cat >"$SANDBOX/run.mjs" <<EOF
import plugin from "$dir/plugins/byrde-agents.mjs"
const hooks = {}
const ctx = {
  tool: { hook: async (n, f) => { hooks["tool." + n] = f } },
  session: { hook: async (n, f) => { hooks["session." + n] = f } },
}
await plugin.setup(ctx)
const dev = { agent: "develop", system: [] }; hooks["session.context"](dev)
const build = { agent: "build", system: [] }; hooks["session.context"](build)
const results = []
for (let i = 1; i <= 3; i++) {
  const e = { status: "completed", sessionID: "s", tool: "read", result: { content: [{ type: "text", text: "r" + i }] } }
  hooks["tool.execute.after"](e)
  results.push(e.result.content.map((p) => p.text).join("|"))
}
console.log(JSON.stringify({ dev: dev.system.map((p) => p.text).join("\n"), build: build.system.map((p) => p.text).join("\n"), results }))
EOF
  local out
  if command -v bun >/dev/null 2>&1; then
    out="$(BYRDE_RULES_REINJECT_EVERY=3 bun "$SANDBOX/run.mjs" 2>&1)" || fail "the plugin did not run: $out"
  else
    out="$(BYRDE_RULES_REINJECT_EVERY=3 node "$SANDBOX/run.mjs" 2>&1)" || fail "the plugin did not run: $out"
  fi
  assert_contains "$(jq -r '.dev' <<<"$out")" "DEVELOP_METHOD_MARKER" "the develop agent did not get its skill"
  assert_contains "$(jq -r '.dev' <<<"$out")" "MEMORY_INDEX_MARKER" "the agent did not get the memory index"
  assert_not_contains "$(jq -r '.build' <<<"$out")" "DEVELOP_METHOD_MARKER" "a non-practice agent got a skill"
  assert_contains "$(jq -r '.build' <<<"$out")" "MEMORY_INDEX_MARKER" "every agent should get the memory index"
  assert_eq "r1" "$(jq -r '.results[0]' <<<"$out")" "the rules were injected before the cadence boundary"
  assert_contains "$(jq -r '.results[2]' <<<"$out")" "GLOBAL_RULE_MARKER" "the third tool result does not carry the lead rule"
  assert_contains "$(jq -r '.results[2]' <<<"$out")" "development.md" "the other rules are not named"
  assert_not_contains "$(jq -r '.results[2]' <<<"$out")" "description: d" "the rule frontmatter leaked"
}

run_tests
