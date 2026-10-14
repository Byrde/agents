#!/usr/bin/env bash
# Configure the OpenCode model router: score the models this project can use
# against public benchmarks and give each task the model that suits it best.
#
# Tasks and practice skills are kept in step both ways: each practice skill
# (plan, develop, review, …) has a task, and each task names its skill.
#
# How routing works: every task in the config becomes an OpenCode subagent
# (.opencode/agents/route-<task>.md) pinned to the model chosen for it. The main
# agent reads each subagent's "delegate here when …" description, and the
# byrde-agents plugin adds a routing table to its system prompt, so a request
# that matches a task is handed to that task's model without anyone asking.
# A command per task (/route-<task>) is the manual override.
#
# The scoring runs only when asked (`evaluate`), never per request. Scores and
# assignments are written back into the config, which is committed with the
# project. The tasks, the dimensions and their weights are written together
# with the agent through the model-router skill.
#
# Data:
#   - the models OpenCode can use here     opencode api GET /api/model
#   - the same model under every provider  the models.dev catalogue OpenCode
#                                          uses (canonical_model_id)
#   - benchmarks, price and speed          Artificial Analysis free API
#                                          (attribution required: generated
#                                          files and reports credit it)
#
# Auth — NO SECRETS ON DISK: the Artificial Analysis key is read from
# ARTIFICIAL_ANALYSIS_API_KEY and sent on curl's stdin, so it is never written
# to a file or shown in the process list. The /api/model response carries
# provider settings (API keys among them); only ids, variants, capabilities
# and limits are kept from it.
#
# Run from the folder your agent opens in (the one that contains .agents):
#   cd /your/project && .agents/scripts/setup/setup-model-router.sh            # install
#   cd /your/project && .agents/scripts/setup/setup-model-router.sh evaluate   # score + assign
#
# Writes:
#   - .opencode/model-router.json         tasks (one per practice skill), criteria,
#                                         providers, evaluation (commit it)
#   - .opencode/agents/route-*.md         one subagent per task (commit them)
#   - .opencode/commands/route-*.md       one command per task (commit them)
#   - .opencode/.model-router/            cached API responses (gitignored)
#   - skills/model-router/SKILL.md (+ mirrored for each harness init chose)
#
# Requires: jq, python3, curl, opencode (2.x). Bash 3.2 (macOS) compatible.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENTS_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=lib/layout.sh
. "$SCRIPT_DIR/../lib/layout.sh"
resolve_layout
# shellcheck source=lib/manifest.sh
. "$SCRIPT_DIR/../lib/manifest.sh"
# shellcheck source=lib/harness.sh
. "$SCRIPT_DIR/../lib/harness.sh"

TOOL_DIR="$AGENTS_ROOT/tools"
ROUTER_TEMPLATE="$TOOL_DIR/model-router.md.template"
ROUTER_OUT="$SKILLS_DIR/model-router/SKILL.md"
ROUTER_PY="$SCRIPT_DIR/../lib/model_router.py"

CONFIG="$WORKSPACE_ROOT/.opencode/model-router.json"
# Practice skills ship in the library; each one is a task's method.
SKILL_DIRS=("$AGENTS_ROOT/skills")
CACHE_DIR="$WORKSPACE_ROOT/.opencode/.model-router"

AA_URL="${MODEL_ROUTER_AA_URL:-https://artificialanalysis.ai/api/v2/data/llms/models}"
CATALOG_URL="${MODEL_ROUTER_CATALOG_URL:-https://models.opencode.ai/api.json}"
OPENCODE_BIN="${BYRDE_OPENCODE_BIN:-opencode}"

TOOL_VERSION="0.1.0"
PROG_NAME="$(basename "${BASH_SOURCE[0]}")"

die() {
  echo "error: $*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing required command: $1 (install or add to PATH)"
}

bar() { printf '%*s' 68 '' | tr ' ' '='; }

print_intro() {
  local b; b="$(bar)"
  echo "$b"
  echo "  $PROG_NAME · Byrde Agents  v$TOOL_VERSION"
  echo ""
  echo "  $1"
  echo ""
  printf '  %-16s %s\n' "Context Root" "$WORKSPACE_ROOT"
  printf '  %-16s %s\n' "Config" "${CONFIG#"$WORKSPACE_ROOT"/}"
  echo "$b"
  echo ""
}

require_opencode_harness() {
  harness_has opencode \
    || die "the model router is for OpenCode, and init did not select it. Run: .agents/scripts/init.sh --harness opencode[,…]"
}

# ─── Data ────────────────────────────────────────────────────────────────────

# The models OpenCode can use in this project, reduced to what scoring needs.
# MODEL_ROUTER_MODELS_FILE replaces the live call (tests, offline runs).
fetch_models() {
  local out="$1" raw
  raw="$(mktemp "${TMPDIR:-/tmp}/byrde-models.XXXXXX")"
  if [[ -n "${MODEL_ROUTER_MODELS_FILE:-}" ]]; then
    cp "$MODEL_ROUTER_MODELS_FILE" "$raw"
  else
    require_cmd "$OPENCODE_BIN"
    # A private server reads this project's current config, not a cached one.
    if ! (cd "$WORKSPACE_ROOT" && "$OPENCODE_BIN" api --standalone GET /api/model >"$raw" 2>/dev/null); then
      rm -f "$raw"
      die "could not list models with '$OPENCODE_BIN api --standalone GET /api/model' (is OpenCode 2 installed?)"
    fi
  fi
  # Keep ids, variants, capabilities and limits. Provider settings (API keys)
  # stay behind in $raw, which is deleted.
  if ! jq '[(.data // .)[]
        | select(.enabled != false and .status != "deprecated")
        | select((.capabilities.output // ["text"]) | index("text"))
        | {providerID, id, modelID: (.modelID // .id), name,
           variants: [(.variants // [])[] | .id],
           tools: (.capabilities.tools // false),
           input: (.capabilities.input // ["text"]),
           context: (.limit.context // 0)}]' "$raw" >"$out" 2>/dev/null; then
    rm -f "$raw"
    die "unexpected /api/model response"
  fi
  rm -f "$raw"
}

fetch_catalog() {
  local out="$1"
  if [[ -n "${MODEL_ROUTER_CATALOG_FILE:-}" ]]; then
    cp "$MODEL_ROUTER_CATALOG_FILE" "$out"
    return 0
  fi
  curl -fsS --max-time 120 "$CATALOG_URL" -o "$out.tmp" || die "could not download the model catalogue from $CATALOG_URL"
  mv "$out.tmp" "$out"
}

fetch_aa() {
  local out="$1"
  if [[ -n "${MODEL_ROUTER_AA_FILE:-}" ]]; then
    cp "$MODEL_ROUTER_AA_FILE" "$out"
    return 0
  fi
  [[ -n "${ARTIFICIAL_ANALYSIS_API_KEY:-}" ]] \
    || die "set ARTIFICIAL_ANALYSIS_API_KEY (free key: https://artificialanalysis.ai/), or run 'evaluate --offline' to reuse the last download"
  # The header goes in on stdin: never on disk, never in `ps`.
  printf 'x-api-key: %s\n' "$ARTIFICIAL_ANALYSIS_API_KEY" \
    | curl -fsS --max-time 120 -H @- "$AA_URL" -o "$out.tmp" \
    || { rm -f "$out.tmp"; die "the Artificial Analysis API refused the request (check the key; the free tier allows 1,000 requests a day)"; }
  mv "$out.tmp" "$out"
}

prepare_cache() {
  mkdir -p "$CACHE_DIR"
  # Ignored from inside, so the project's own .gitignore stays untouched.
  [[ -f "$CACHE_DIR/.gitignore" ]] || printf '*\n' >"$CACHE_DIR/.gitignore"
}

# ─── Skills ↔ tasks ──────────────────────────────────────────────────────────

# One task per practice skill, both ways: a new skill gets a task, a task
# without a skill is reported.
sync_skills() {
  echo ""
  echo "── Skills ↔ tasks ──"
  local out
  out="$(python3 "$ROUTER_PY" sync "$CONFIG" "${SKILL_DIRS[@]}")"
  if [[ -n "$out" ]]; then echo "$out"; else echo "  every practice skill has a task, and every task a skill"; fi
}

# ─── Skill ───────────────────────────────────────────────────────────────────

render_skill() {
  [[ -f "$ROUTER_TEMPLATE" ]] || die "missing template: $ROUTER_TEMPLATE"
  mkdir -p "$(dirname "$ROUTER_OUT")"
  sed "s#{{SETUP}}#.agents/scripts/setup/$PROG_NAME#g" "$ROUTER_TEMPLATE" >"$ROUTER_OUT"
  echo "Wrote $ROUTER_OUT"
}

# ─── Commands ────────────────────────────────────────────────────────────────

install() {
  require_cmd jq
  require_cmd python3
  require_opencode_harness
  print_intro "Score this project's models per task and route each task to its best model."

  echo "── Config ──"
  mkdir -p "$(dirname "$CONFIG")"
  prepare_cache
  if [[ -f "$CONFIG" ]]; then
    echo "  kept ${CONFIG#"$WORKSPACE_ROOT"/}"
  else
    fetch_models "$CACHE_DIR/models.json"
    python3 "$ROUTER_PY" init "$CONFIG" "$CACHE_DIR/models.json" "${SKILL_DIRS[@]}" | sed 's/^/  /'
    echo "  providers: $(jq -r '.providers | join(", ")' "$CONFIG")"
  fi
  sync_skills

  echo ""
  echo "── Installing model-router skill ──"
  ignore_skills_home
  render_skill
  harness_skill_sync "$WORKSPACE_ROOT" "$SKILLS_DIR/model-router"
  manifest_add "model-router"

  echo ""
  echo "Done. Next:"
  echo "  1. Ask the agent to set up model routing: it walks through the tasks,"
  echo "     what matters for each, and the provider order, and edits the config."
  echo "  2. Score and assign:  ARTIFICIAL_ANALYSIS_API_KEY=… .agents/scripts/setup/$PROG_NAME evaluate"
  echo "  3. Restart OpenCode so it loads the routed subagents."
}

evaluate_cmd() {
  local offline=0
  [[ "${1:-}" == "--offline" ]] && offline=1
  require_cmd jq
  require_cmd python3
  require_opencode_harness
  [[ -f "$CONFIG" ]] || die "no config yet: run $PROG_NAME first"
  print_intro "Evaluate: score the configured providers' models and assign one per task."

  sync_skills
  echo ""
  prepare_cache
  if [[ "$offline" -eq 1 ]]; then
    local f
    for f in models catalog aa; do
      [[ -s "$CACHE_DIR/$f.json" ]] || die "--offline needs a previous evaluate (missing ${CACHE_DIR#"$WORKSPACE_ROOT"/}/$f.json)"
    done
    echo "  reusing the data from the last evaluate"
  else
    require_cmd curl
    echo "  models available here …";      fetch_models "$CACHE_DIR/models.json"
    echo "  model catalogue …";            fetch_catalog "$CACHE_DIR/catalog.json"
    echo "  Artificial Analysis data …";   fetch_aa "$CACHE_DIR/aa.json"
  fi
  echo ""
  python3 "$ROUTER_PY" evaluate "$CONFIG" "$CACHE_DIR/models.json" "$CACHE_DIR/catalog.json" "$CACHE_DIR/aa.json" "$WORKSPACE_ROOT"
  echo ""
  echo "Done. Commit .opencode/model-router.json, .opencode/agents/ and .opencode/commands/."
  echo "  Restart OpenCode so it loads the routed subagents."
}

uninstall() {
  require_cmd jq
  local b; b="$(bar)"
  echo "$b"
  echo "  $PROG_NAME · Uninstall  v$TOOL_VERSION"
  echo ""
  echo "  Removes the routed subagents and commands, the cached data and the"
  echo "  model-router skill. Keeps .opencode/model-router.json — the tasks and"
  echo "  criteria in it are yours; delete it by hand if you want it gone."
  echo "$b"
  echo ""
  if [[ -f "$CONFIG" ]] && command -v python3 >/dev/null 2>&1; then
    python3 "$ROUTER_PY" clean "$CONFIG" "$WORKSPACE_ROOT"
  fi
  rm -rf "$CACHE_DIR"
  harness_skill_purge "$WORKSPACE_ROOT" "model-router"
  rm -rf "$SKILLS_DIR/model-router"
  echo "  removed skills/model-router (and its copies in every harness)"
  manifest_remove "model-router"
  echo ""
  echo "Done. Restart OpenCode so it drops the routed subagents."
}

main() {
  case "${1:-}" in
    -h | --help | help)
      echo "$PROG_NAME · Byrde Agents v$TOOL_VERSION"
      echo ""
      echo "Routes each kind of task to the model that suits it best, in OpenCode."
      echo ""
      echo "Usage:"
      echo "  cd /your/project && $0                       # install: starter config + skill"
      echo "  cd /your/project && $0 evaluate              # score models, assign one per task"
      echo "  cd /your/project && $0 evaluate --offline    # re-score from the last download"
      echo "  cd /your/project && $0 show                  # print the current assignments"
      echo "  cd /your/project && $0 uninstall             # remove subagents, commands, skill"
      echo ""
      echo "Environment:"
      echo "  ARTIFICIAL_ANALYSIS_API_KEY  Artificial Analysis API key (needed by evaluate)."
      exit 0
      ;;
    evaluate) shift; evaluate_cmd "$@" ;;
    show)
      [[ -f "$CONFIG" ]] || die "no config yet: run $PROG_NAME first"
      python3 "$ROUTER_PY" show "$CONFIG"
      ;;
    uninstall | remove) uninstall ;;
    "") install ;;
    *) die "unknown command: $1 (see --help)" ;;
  esac
}

main "$@"
