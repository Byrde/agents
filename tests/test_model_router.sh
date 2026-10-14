#!/usr/bin/env bash
# test_model_router.sh — the OpenCode model router scores, assigns, renders and
# cleans up the way setup-model-router.sh promises.
#
# No network, no session, no cost: the models, the catalogue and the benchmark
# data are small hand-made fixtures shaped like the real responses. Their
# numbers are chosen so each rule under test decides an outcome.
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/harness.sh"

ROUTER="$REPO_ROOT/scripts/lib/model_router.py"
SETUP_REL=".agents/scripts/setup/setup-model-router.sh"

# ─── Fixtures ────────────────────────────────────────────────────────────────
#
# Benchmarks (Artificial Analysis /data/llms/models shape):
#   alpha-1      (High)  strong, pricey, slow     — its -low twin is fast
#   beta-2       cheapest, speed never measured   — must not win on missing data
#   gamma-3-preview      cheap and quick          — catalogue calls it gamma-3
#   tiny-1       the strongest, but 1k context    — fails a context floor
#   f-*          fillers that give the percentiles a population

write_aa() {
  cat >"$1" <<'EOF'
{"status":200,"data":[
 {"slug":"alpha-1","name":"Alpha 1 (High)","model_creator":{"slug":"acme"},
  "evaluations":{"artificial_analysis_intelligence_index":60,"artificial_analysis_coding_index":70},
  "pricing":{"price_1m_blended_3_to_1":10},"median_output_tokens_per_second":50,"median_time_to_first_answer_token":20},
 {"slug":"alpha-1-low","name":"Alpha 1 (Low)","model_creator":{"slug":"acme"},
  "evaluations":{"artificial_analysis_intelligence_index":45,"artificial_analysis_coding_index":55},
  "pricing":{"price_1m_blended_3_to_1":10},"median_output_tokens_per_second":150,"median_time_to_first_answer_token":2},
 {"slug":"beta-2","name":"Beta 2","model_creator":{"slug":"acme"},
  "evaluations":{"artificial_analysis_intelligence_index":50,"artificial_analysis_coding_index":50},
  "pricing":{"price_1m_blended_3_to_1":0.4},"median_output_tokens_per_second":0,"median_time_to_first_answer_token":0},
 {"slug":"gamma-3-preview","name":"Gamma 3","model_creator":{"slug":"acme"},
  "evaluations":{"artificial_analysis_intelligence_index":30,"artificial_analysis_coding_index":30},
  "pricing":{"price_1m_blended_3_to_1":0.5},"median_output_tokens_per_second":100,"median_time_to_first_answer_token":1},
 {"slug":"tiny-1","name":"Tiny 1","model_creator":{"slug":"acme"},
  "evaluations":{"artificial_analysis_intelligence_index":90},
  "pricing":{"price_1m_blended_3_to_1":5},"median_output_tokens_per_second":80,"median_time_to_first_answer_token":5},
 {"slug":"f-one","name":"F1","model_creator":{"slug":"x"},"evaluations":{"artificial_analysis_intelligence_index":20},
  "pricing":{"price_1m_blended_3_to_1":20},"median_output_tokens_per_second":30,"median_time_to_first_answer_token":10},
 {"slug":"f-two","name":"F2","model_creator":{"slug":"x"},"evaluations":{"artificial_analysis_intelligence_index":40},
  "pricing":{"price_1m_blended_3_to_1":2},"median_output_tokens_per_second":60,"median_time_to_first_answer_token":3},
 {"slug":"f-three","name":"F3","model_creator":{"slug":"x"},"evaluations":{"artificial_analysis_intelligence_index":35},
  "pricing":{"price_1m_blended_3_to_1":8},"median_output_tokens_per_second":120,"median_time_to_first_answer_token":1}
]}
EOF
}

# The models.dev catalogue: canonical_model_id ties prov-b's alpha to prov-a's.
write_catalog() {
  cat >"$1" <<'EOF'
{"prov-a":{"id":"prov-a","models":{
   "alpha-1":{"id":"alpha-1","canonical_model_id":"acme/alpha-1"},
   "beta-2":{"id":"beta-2","canonical_model_id":"acme/beta-2"},
   "gamma-3":{"id":"gamma-3","canonical_model_id":"acme/gamma-3"},
   "embed":{"id":"embed","canonical_model_id":"acme/embed"}}},
 "prov-b":{"id":"prov-b","models":{
   "acme-alpha-1":{"id":"acme-alpha-1","canonical_model_id":"acme/alpha-1"},
   "tiny":{"id":"tiny","canonical_model_id":"acme/tiny-1"}}}}
EOF
}

# OpenCode's /api/model response, provider settings (secrets) included.
write_models() {
  python3 - "$1" <<'PY'
import json, sys
def m(p, i, variants=(), tools=True, ctx=200000):
    return {"providerID": p, "id": i, "modelID": i, "name": i,
            "settings": {"apiKey": "SECRET_FIXTURE_KEY"},
            "capabilities": {"tools": tools, "input": ["text"], "output": ["text"]},
            "variants": [{"id": v, "settings": {}} for v in variants],
            "status": "active", "enabled": True, "limit": {"context": ctx, "output": 1000}}
data = [m("prov-a", "alpha-1", ["low", "high"]), m("prov-a", "beta-2"), m("prov-a", "gamma-3"),
        m("prov-a", "embed", tools=False), m("prov-b", "acme-alpha-1", ["low", "high"]),
        m("prov-b", "tiny", ctx=1000), m("prov-c", "mystery")]
json.dump({"location": {}, "data": data}, open(sys.argv[1], "w"))
PY
}

# The reduced form setup-model-router.sh hands to model_router.py.
reduce_models() {
  jq '[(.data // .)[] | {providerID, id, modelID, name, variants: [.variants[].id],
       tools: .capabilities.tools, input: .capabilities.input, context: .limit.context}]' "$1" >"$2"
}

write_config() {
  cat >"$1" <<'EOF'
{
  "providers": ["prov-b", "prov-a", "prov-c"],
  "requirements": {"tools": true},
  "minCoverage": 0.5,
  "commands": true,
  "exclude": [],
  "aliases": {},
  "metrics": {},
  "dimensions": {
    "intelligence": {"metrics": {"intelligence_index": 1}},
    "cost": {"metrics": {"price": 1}},
    "speed": {"metrics": {"output_speed": 0.6, "latency": 0.4}}
  },
  "tasks": {
    "think": {"description": "Hard thinking", "when": "the problem is hard",
              "weights": {"intelligence": 1}, "require": {"minContext": 100000}},
    "cheap": {"description": "Cheap and quick", "when": "the change is small",
              "weights": {"speed": 0.5, "cost": 0.5}},
    "fast":  {"description": "Fast", "when": "speed matters", "weights": {"speed": 1}}
  }
}
EOF
}

# fixtures — write every input under $SANDBOX and evaluate once.
fixtures() {
  write_aa "$SANDBOX/aa.json"
  write_catalog "$SANDBOX/catalog.json"
  write_models "$SANDBOX/raw-models.json"
  reduce_models "$SANDBOX/raw-models.json" "$SANDBOX/models.json"
  mkdir -p "$SANDBOX/p/.opencode"
  write_config "$SANDBOX/p/.opencode/model-router.json"
}

evaluate() {
  python3 "$ROUTER" evaluate "$SANDBOX/p/.opencode/model-router.json" "$SANDBOX/models.json" \
    "$SANDBOX/catalog.json" "$SANDBOX/aa.json" "$SANDBOX/p"
}

need() {
  command -v jq >/dev/null 2>&1 || skip "jq is not on PATH"
  command -v python3 >/dev/null 2>&1 || skip "python3 is not on PATH"
}

CFG_FILTER='.evaluation.assignments'

# ─── Scoring ─────────────────────────────────────────────────────────────────

test_the_best_model_wins_through_the_first_listed_provider() {
  need; fixtures
  evaluate >/dev/null || fail "evaluate failed"
  local cfg="$SANDBOX/p/.opencode/model-router.json"
  # tiny-1 scores higher but has 1k context; alpha-1 at high effort is next.
  assert_json "$cfg" "$CFG_FILTER.think.model" "prov-b/acme-alpha-1#high" \
    "the context floor, the effort variant or the provider order was not applied"
  assert_json "$cfg" "$CFG_FILTER.think.canonical" "acme/alpha-1#high" "the canonical id is wrong"
  assert_json "$cfg" "$CFG_FILTER.think.providers | join(\",\")" "prov-b,prov-a" \
    "both providers of the model should be listed, in priority order"
}

test_the_effort_variant_follows_the_benchmark_entry() {
  need; fixtures
  evaluate >/dev/null || fail "evaluate failed"
  assert_json "$SANDBOX/p/.opencode/model-router.json" "$CFG_FILTER.fast.model" "prov-b/acme-alpha-1#low" \
    "the fast low-effort entry should pin the #low variant"
}

test_an_unmeasured_dimension_counts_as_the_median() {
  need; fixtures
  evaluate >/dev/null || fail "evaluate failed"
  # beta-2 is the cheapest but its speed was never measured. Skipping the
  # dimension would hand it the task on price alone.
  assert_json "$SANDBOX/p/.opencode/model-router.json" "$CFG_FILTER.cheap.model" "prov-a/gamma-3" \
    "a model with no speed data escaped the speed weight"
}

test_unmatched_models_are_reported_and_aliases_settle_them() {
  need; fixtures
  local cfg="$SANDBOX/p/.opencode/model-router.json" out
  out="$(evaluate)" || fail "evaluate failed"
  assert_contains "$out" "prov-c/mystery" "the unmatched model was not reported"
  assert_not_contains "$out" "embed" "a model that cannot serve any task was reported as unmatched"
  assert_json "$cfg" '.evaluation.unmatched | map(.canonical) | join(",")' "prov-c/mystery" \
    "the unmatched list is wrong"

  jq '.aliases = {"prov-c/mystery": "beta-2"}' "$cfg" >"$cfg.t" && mv "$cfg.t" "$cfg"
  evaluate >/dev/null || fail "evaluate with an alias failed"
  assert_json "$cfg" '.evaluation.unmatched | length' "0" "the alias did not match the model"
  assert_json "$cfg" '[.evaluation.candidates[].model] | index("prov-c/mystery") != null' "true" \
    "the aliased model was not scored"

  jq '.aliases = {"prov-c/mystery": null}' "$cfg" >"$cfg.t" && mv "$cfg.t" "$cfg"
  evaluate >/dev/null || fail "evaluate with a null alias failed"
  assert_json "$cfg" '.evaluation.unmatched | length' "0" "a null alias should skip the model quietly"
  assert_json "$cfg" '[.evaluation.candidates[].model] | index("prov-c/mystery") == null' "true" \
    "a null alias should keep the model out of scoring"
}

test_the_same_inputs_give_the_same_evaluation() {
  need; fixtures
  local cfg="$SANDBOX/p/.opencode/model-router.json"
  evaluate >/dev/null; jq -S . "$cfg" >"$SANDBOX/first.json"
  evaluate >/dev/null; jq -S . "$cfg" >"$SANDBOX/second.json"
  assert_eq "$(cat "$SANDBOX/first.json")" "$(cat "$SANDBOX/second.json")" "two evaluations of the same data differ"
}

test_tasks_inherit_their_profile_and_override_it() {
  need; fixtures
  local cfg="$SANDBOX/p/.opencode/model-router.json" out
  # think and think2 share a profile; fast2 inherits it but overrides it to speed.
  jq '.profiles = {"brainy": {"intelligence": 1}}
      | .tasks = {
          "think":  {"profile": "brainy", "when": "hard", "require": {"minContext": 100000}},
          "think2": {"profile": "brainy", "when": "hard too", "require": {"minContext": 100000}},
          "fast2":  {"profile": "brainy", "weights": {"intelligence": 0, "speed": 1}}
        }' "$cfg" >"$cfg.t" && mv "$cfg.t" "$cfg"
  evaluate >/dev/null || fail "evaluate failed"
  assert_json "$cfg" "$CFG_FILTER.think.model" "prov-b/acme-alpha-1#high" "a task did not score with its profile"
  assert_json "$cfg" "$CFG_FILTER.think2.model" "prov-b/acme-alpha-1#high" "tasks sharing a profile got different models"
  assert_json "$cfg" "$CFG_FILTER.think.profile" "brainy" "the assignment does not record its profile"
  assert_json "$cfg" "$CFG_FILTER.fast2.model" "prov-b/acme-alpha-1#low" \
    "an override did not replace the profile, or a 0 weight did not remove its dimension"

  jq '.tasks.think.profile = "nope"' "$cfg" >"$cfg.t" && mv "$cfg.t" "$cfg"
  out="$(evaluate 2>&1)" && fail "a task with an unknown profile was evaluated"
  assert_contains "$out" "unknown profile 'nope'" "the error does not name the profile"
}

test_starter_tasks_on_one_profile_share_a_model() {
  need; fixtures
  local cfg="$SANDBOX/p/.opencode/model-router.json"
  python3 "$ROUTER" init "$SANDBOX/starter.json" "$SANDBOX/models.json" "$REPO_ROOT/skills" >/dev/null || fail "init failed"
  assert_json "$SANDBOX/starter.json" '[.tasks[] | select(.profile == null)] | length' "0" "a starter task has no profile"
  assert_json "$SANDBOX/starter.json" '[.tasks[].profile] | unique | join(",")' "build,deep,fast,write" \
    "the starter tasks do not use the four profiles"
  jq '.providers = ["prov-b", "prov-a", "prov-c"]' "$SANDBOX/starter.json" >"$cfg"
  evaluate >/dev/null || fail "evaluate failed"
  assert_json "$cfg" '[.evaluation.assignments | (.plan, .architect, .design) | .model] | unique | length' "1" \
    "the deep tasks without overrides were split across models"
}

# ─── Rendering ───────────────────────────────────────────────────────────────

test_each_task_becomes_a_pinned_subagent_with_no_prompt() {
  need; fixtures
  evaluate >/dev/null || fail "evaluate failed"
  local agent="$SANDBOX/p/.opencode/agents/route-think.md" cmd="$SANDBOX/p/.opencode/commands/route-think.md"
  assert_file "$agent" "the subagent was not written"
  assert_contains "$(cat "$agent")" 'model: "prov-b/acme-alpha-1#high"' "the subagent is not pinned to its model"
  assert_contains "$(cat "$agent")" "mode: subagent" "the agent is not a subagent"
  assert_contains "$(cat "$agent")" "Delegate here when the problem is hard" "the trigger is missing from the description"
  # A body would replace OpenCode's default system prompt.
  assert_eq "---" "$(tail -n 1 "$agent")" "the subagent has a prompt body"
  assert_contains "$(cat "$cmd")" "subagent: true" "the command does not run in a child session"
  assert_contains "$(cat "$cmd")" 'agent: "route-think"' "the command does not use the task's subagent"
}

test_rendering_owns_only_its_own_files() {
  need; fixtures
  local cfg="$SANDBOX/p/.opencode/model-router.json" mine="$SANDBOX/p/.opencode/agents/route-fast.md"
  mkdir -p "$(dirname "$mine")"
  printf -- '---\ndescription: mine\nmode: subagent\n---\n' >"$mine"
  evaluate >/dev/null || fail "evaluate failed"
  assert_eq "mine" "$(sed -n 's/^description: //p' "$mine")" "the user's own agent was overwritten"
  assert_json "$cfg" '.evaluation.generated | index(".opencode/agents/route-fast.md") == null' "true" \
    "a file the router did not write was recorded as its own"

  # Drop a task and the commands: their files go, the user's stays.
  jq 'del(.tasks.cheap) | .commands = false' "$cfg" >"$cfg.t" && mv "$cfg.t" "$cfg"
  evaluate >/dev/null || fail "re-evaluate failed"
  assert_no_file "$SANDBOX/p/.opencode/agents/route-cheap.md" "a dropped task kept its subagent"
  assert_no_file "$SANDBOX/p/.opencode/commands" "commands: false left the commands behind"
  assert_file "$mine" "the user's own agent was removed"

  python3 "$ROUTER" clean "$cfg" "$SANDBOX/p" >/dev/null || fail "clean failed"
  assert_no_file "$SANDBOX/p/.opencode/agents/route-think.md" "clean left a subagent behind"
  assert_file "$mine" "clean removed the user's own agent"
  assert_file "$cfg" "clean removed the config"
}

# ─── Skills ↔ tasks ───────────────────────────────────────────────────────────

# practice_skill <dir> <name> — a practice skill in the shape the library uses.
practice_skill() {
  mkdir -p "$1/$2"
  printf -- '---\nname: %s\ndescription: "**MUST be invoked** before you ship a %s. NEVER skip it. Skipping it hurts. Ship the %s carefully."\ncategory: practice\n---\n' \
    "$2" "$2" "$2" >"$1/$2/SKILL.md"
}

test_sync_gives_every_practice_skill_a_task_and_reports_skillless_tasks() {
  need; fixtures
  local cfg="$SANDBOX/p/.opencode/model-router.json" sk="$SANDBOX/skills" out rc
  practice_skill "$sk" think   # links to the existing task of that name
  practice_skill "$sk" deploy  # has no task yet
  mkdir -p "$sk/tooly" && printf -- '---\nname: tooly\ncategory: tool\n---\n' >"$sk/tooly/SKILL.md"

  out="$(python3 "$ROUTER" sync "$cfg" "$sk" --check)"; rc=$?
  assert_eq "3" "$rc" "--check did not report the drift"
  assert_json "$cfg" '.tasks | has("deploy")' "false" "--check wrote to the config"

  out="$(python3 "$ROUTER" sync "$cfg" "$sk")" || fail "sync failed: $out"
  assert_json "$cfg" '.tasks.think.skill' "think" "a task named like a skill was not linked to it"
  assert_json "$cfg" '.tasks.deploy.skill' "deploy" "a practice skill got no task"
  assert_json "$cfg" '.tasks.deploy.when' "you are about to ship a deploy" "the trigger was not taken from the skill"
  assert_json "$cfg" '.tasks.deploy.seeded' "true" "a seeded profile is not marked for checking"
  assert_json "$cfg" '.tasks.deploy.profile' "deep" "a seeded task got no profile"
  assert_json "$cfg" '.profiles | has("deep")' "true" "sync did not add the profile a seeded task needs"
  assert_json "$cfg" '.tasks | has("tooly")' "false" "a tool skill got a routing task"
  assert_contains "$out" "task 'cheap' has no practice skill" "a task without a skill was not reported"

  # A skill the user opted out of stays out, even after its task is dropped.
  jq 'del(.tasks.deploy) | .skipSkills = ["deploy"] | .tasks |= with_entries(select(.value.skill))' "$cfg" >"$cfg.t" && mv "$cfg.t" "$cfg"
  python3 "$ROUTER" sync "$cfg" "$sk" --check >/dev/null; rc=$?
  assert_eq "0" "$rc" "skills and tasks should be in step"
  assert_json "$cfg" '.tasks | has("deploy")' "false" "skipSkills did not keep the task out"
}

test_a_subagent_names_the_skill_it_follows() {
  need; fixtures
  local cfg="$SANDBOX/p/.opencode/model-router.json"
  jq '.tasks.think.skill = "think"' "$cfg" >"$cfg.t" && mv "$cfg.t" "$cfg"
  evaluate >/dev/null || fail "evaluate failed"
  assert_contains "$(cat "$SANDBOX/p/.opencode/agents/route-think.md")" "Follows the think skill." \
    "the subagent does not say which skill it follows"
}

# ─── Plugin ──────────────────────────────────────────────────────────────────

test_the_plugin_routes_delegating_agents_and_redirects_routed_skills() {
  need
  command -v bun >/dev/null 2>&1 || command -v node >/dev/null 2>&1 || skip "neither bun nor node is on PATH"
  fixtures
  local dir="$SANDBOX/p/.opencode"
  mkdir -p "$dir/agents"
  printf -- '---\ndescription: mine\n---\n' >"$dir/agents/route-fast.md"  # not the router's
  jq '.tasks.think.skill = "think"' "$dir/model-router.json" >"$dir/t" && mv "$dir/t" "$dir/model-router.json"
  evaluate >/dev/null || fail "evaluate failed"
  mkdir -p "$dir/plugins"
  cp "$REPO_ROOT/scripts/hooks/opencode/byrde-agents.js" "$dir/plugins/byrde-agents.mjs"
  echo '{}' >"$dir/byrde-agents.json"
  cat >"$SANDBOX/run.mjs" <<EOF
import plugin from "$dir/plugins/byrde-agents.mjs"
const hooks = {}
const reg = (p) => ({ hook: async (n, f) => { hooks[p + n] = f } })
await plugin.setup({ tool: reg("tool."), permission: reg("permission."), session: reg("session.") })
const run = (agent, tools) => { const e = { agent, tools, system: [] }; hooks["session.context"](e); return e.system.map((p) => p.text).join("") }
const load = (agent, id) => {
  const e = { status: "completed", tool: "skill", agent, sessionID: agent + id, input: { id }, result: { content: [{ type: "text", text: "SKILL BODY" }] } }
  hooks["tool.execute.after"](e)
  return e.result.content.map((p) => p.text).join("|")
}
console.log(JSON.stringify({
  build: run("build", { subagent: {}, read: {} }),
  routed: run("route-think", { subagent: {}, read: {} }),
  noTool: run("build", { read: {} }),
  redirect: load("build", "think"),
  inSubagent: load("route-think", "think"),
  unrouted: load("build", "other"),
}))
EOF
  local out
  if command -v bun >/dev/null 2>&1; then out="$(bun "$SANDBOX/run.mjs")"; else out="$(node "$SANDBOX/run.mjs")"; fi \
    || fail "the plugin did not run: $out"
  local build
  build="$(printf '%s' "$out" | jq -r '.build')"
  assert_contains "$build" "route-think (think skill): the problem is hard (prov-b/acme-alpha-1#high)" \
    "the main agent was not told about the routed task"
  assert_not_contains "$build" "route-fast" "a task whose subagent is the user's own was advertised"
  assert_eq "" "$(printf '%s' "$out" | jq -r '.routed')" "a routed subagent was told to delegate further"
  assert_eq "" "$(printf '%s' "$out" | jq -r '.noTool')" "an agent without the subagent tool got the table"
  assert_contains "$(printf '%s' "$out" | jq -r '.redirect')" "Hand the request to the route-think subagent" \
    "loading a routed skill did not redirect the work to its subagent"
  assert_eq "SKILL BODY" "$(printf '%s' "$out" | jq -r '.inSubagent')" "the routed subagent was redirected away from its own skill"
  assert_eq "SKILL BODY" "$(printf '%s' "$out" | jq -r '.unrouted')" "an unrouted skill was redirected"
}

# ─── Setup script ────────────────────────────────────────────────────────────

make_host() {
  local host="$SANDBOX/host"
  mkdir -p "$host"
  git -C "$host" init -q
  rsync -a --exclude .git --exclude .manifest.local.yml --exclude skills/model-router "$REPO_ROOT/" "$host/.agents/"
  git -C "$host/.agents" init -q
  git -C "$host/.agents" add -A
  git -C "$host/.agents" -c user.email=t@t -c user.name=t commit -qm fixture
  echo "$host"
}

# setup <host> [args…] — the setup script, fed the fixtures instead of the network.
setup() {
  local host="$1"; shift
  (cd "$host" && MODEL_ROUTER_MODELS_FILE="$SANDBOX/raw-models.json" \
     MODEL_ROUTER_CATALOG_FILE="$SANDBOX/catalog.json" MODEL_ROUTER_AA_FILE="$SANDBOX/aa.json" \
     "$SETUP_REL" "$@" </dev/null 2>&1)
}

test_setup_installs_evaluates_and_uninstalls_without_leaking_secrets() {
  need
  command -v rsync >/dev/null 2>&1 || skip "rsync is not on PATH"
  fixtures
  local host out cfg
  host="$(make_host)"; cfg="$host/.opencode/model-router.json"
  (cd "$host" && HOME="$SANDBOX/home" BYRDE_HARNESSES= .agents/scripts/init.sh --harness opencode </dev/null >/dev/null 2>&1) \
    || fail "init failed"

  out="$(setup "$host")" || fail "install failed: $out"
  assert_json "$cfg" '.providers | join(",")' "prov-a,prov-b,prov-c" "the starter config does not list the providers"
  local skills
  skills="$(cd "$REPO_ROOT/skills" && grep -l '^category: practice' */SKILL.md | cut -d/ -f1 | sort | tr '\n' ' ')"
  assert_json "$cfg" '[.tasks | keys[]] | join(" ")' "${skills% }" "the starter tasks are not one per practice skill"
  assert_json "$cfg" '[.tasks | to_entries[] | select(.value.skill != .key)] | length' "0" \
    "a starter task does not name its skill"
  assert_file "$host/.agents/skills/model-router/SKILL.md" "the skill was not installed"
  assert_contains "$(cat "$host/.agents/.manifest.local.yml")" "model-router" "the manifest does not record the router"

  # A re-install keeps the user's config.
  write_config "$cfg"
  setup "$host" >/dev/null || fail "re-install failed"
  assert_json "$cfg" '.tasks | has("think")' "true" "a re-install replaced the user's config"

  out="$(setup "$host" evaluate)" || fail "evaluate failed: $out"
  assert_contains "$out" "Artificial Analysis" "the report does not credit Artificial Analysis"
  assert_file "$host/.opencode/agents/route-think.md" "evaluate did not write the subagents"
  assert_eq "*" "$(cat "$host/.opencode/.model-router/.gitignore")" "the cache is not gitignored"
  assert_empty "$(grep -rl SECRET_FIXTURE_KEY "$host/.opencode" "$host/.agents/skills" "${TMPDIR:-/tmp}"/byrde-models.* 2>/dev/null)" \
    "a provider secret from /api/model was written to disk"

  out="$(setup "$host" evaluate --offline)" || fail "evaluate --offline failed: $out"
  assert_contains "$out" "reusing the data from the last evaluate" "--offline fetched again"

  out="$(setup "$host" uninstall)" || fail "uninstall failed: $out"
  assert_no_file "$host/.opencode/agents/route-think.md" "uninstall left a subagent behind"
  assert_no_file "$host/.opencode/.model-router" "uninstall left the cache behind"
  assert_no_file "$host/.agents/skills/model-router" "uninstall left the skill behind"
  assert_file "$cfg" "uninstall removed the user's config"
  assert_empty "$(git -C "$host/.agents" status --short 2>/dev/null)" "the router dirtied the shared checkout"
}

test_setup_refuses_without_opencode_or_a_key() {
  need
  command -v rsync >/dev/null 2>&1 || skip "rsync is not on PATH"
  fixtures
  local host out
  host="$(make_host)"
  (cd "$host" && HOME="$SANDBOX/home" BYRDE_HARNESSES= .agents/scripts/init.sh --harness claude </dev/null >/dev/null 2>&1) \
    || fail "init failed"
  out="$(setup "$host")" && fail "install ran without OpenCode selected"
  assert_contains "$out" "init did not select it" "the refusal does not say why"

  (cd "$host" && HOME="$SANDBOX/home" BYRDE_HARNESSES= .agents/scripts/init.sh --harness opencode </dev/null >/dev/null 2>&1)
  setup "$host" >/dev/null || fail "install failed"
  out="$(cd "$host" && env -u ARTIFICIAL_ANALYSIS_API_KEY MODEL_ROUTER_MODELS_FILE="$SANDBOX/raw-models.json" \
           MODEL_ROUTER_CATALOG_FILE="$SANDBOX/catalog.json" "$SETUP_REL" evaluate </dev/null 2>&1)" \
    && fail "evaluate ran without an Artificial Analysis key"
  assert_contains "$out" "ARTIFICIAL_ANALYSIS_API_KEY" "the refusal does not name the key"
}

run_tests
