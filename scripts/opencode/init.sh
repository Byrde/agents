#!/usr/bin/env bash
# Bootstrap a project for OpenCode 2 with Byrde Agents.
#
# OpenCode gets its own installer because it takes the practice skills as
# AGENTS, not as skills: each practice skill (plan, develop, debug, …) becomes
# an agent you can switch to, or that the main agent delegates to, and each one
# runs on the model that suits its kind of work.
#
# Every run re-scores the models. It lists the models OpenCode can use here,
# scores them against Artificial Analysis benchmarks, price included, and pins
# each agent to the best one. When the only provider is OpenCode's built-in
# one, or no Artificial Analysis key is set, the agents inherit the session's
# model. Run setup-fuelix.sh to add Fuel iX models as a provider.
#
# Run from the folder you open OpenCode in (the one that contains .agents):
#   cd /your/project && .agents/scripts/opencode/init.sh             # install + evaluate
#   cd /your/project && .agents/scripts/opencode/init.sh evaluate    # re-score only
#   cd /your/project && .agents/scripts/opencode/init.sh uninstall   # remove what install wrote
#
# Writes:
#   - .workspace.agents.json          the workspace repo map (shared with init.sh)
#   - AGENTS.md                       one fenced section per rule in .agents/rules/
#   - .opencode/opencode.json         merged, never replaced: $schema, the
#                                     allow-all permission, a deny for each
#                                     practice skill as a skill (it is an agent
#                                     now), and the GitHub MCP server
#   - .opencode/agents/<skill>.md     one agent per practice skill
#   - .opencode/plugins/byrde-agents.js  skill method, memory, rules re-injection
#   - .opencode/byrde-agents.json     the plugin's settings and the evaluation
#   - .opencode/.byrde/               cached API responses
#   - memory/                         project memory (git-tracked, shared)
#   - .gitignore                      a "byrde-agents opencode" block
#
# Auth — no secrets on disk. ARTIFICIAL_ANALYSIS_API_KEY is sent on curl's
# stdin. The GitHub MCP server reads GITHUB_PERSONAL_ACCESS_TOKEN when OpenCode
# loads the config. OpenCode's model list carries provider settings (API keys
# among them); only ids, variants, capabilities, limits and prices are kept.
#
# Requires: jq, python3, curl, opencode (2.x). Bash 3.2 (macOS) compatible.

set -euo pipefail

OC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_DIR="$(cd "$OC_DIR/.." && pwd)"
AGENTS_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../lib/layout.sh
. "$SCRIPT_DIR/lib/layout.sh"
# shellcheck source=../lib/workspace.sh
. "$SCRIPT_DIR/lib/workspace.sh"
# shellcheck source=lib/root.sh
. "$OC_DIR/lib/root.sh"
# harness.sh (through mcp.sh) gives the fenced-block and frontmatter helpers.
# shellcheck source=../lib/mcp.sh
. "$SCRIPT_DIR/lib/mcp.sh"

SKILLS_SRC="$AGENTS_ROOT/skills"
RULES_SRC="$AGENTS_ROOT/rules"
EVALUATE_PY="$OC_DIR/lib/evaluate.py"
PLUGIN_SRC="$OC_DIR/plugin/byrde-agents.js"

AA_URL="${BYRDE_AA_URL:-https://artificialanalysis.ai/api/v2/data/llms/models}"
CATALOG_URL="${BYRDE_CATALOG_URL:-https://models.opencode.ai/api.json}"
OPENCODE_BIN="${BYRDE_OPENCODE_BIN:-opencode}"

GI_START="# --- byrde-agents opencode ---"
GI_END="# --- end byrde-agents opencode ---"

TOOL_VERSION="0.1.0"
PROG_NAME="opencode/$(basename "${BASH_SOURCE[0]}")"

die() {
  echo "error: $*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing required command: $1 (install it or add it to PATH)"
}

bar() { printf '%*s' 68 '' | tr ' ' '='; }

# Paths under the context root: the folder OpenCode opens.
set_paths() {
  ROOT="$WORKSPACE_ROOT"
  OC="$ROOT/.opencode"
  CFG="$OC/opencode.json"
  STATE="$OC/byrde-agents.json"
  CACHE="$OC/.byrde"
  PLUGIN_DEST="$OC/plugins/byrde-agents.js"
  MEMORY_DIR="$ROOT/memory"
}

# Apply a jq filter to a JSON file in place, creating it from `{}`.
json_edit() {
  local path="$1" filter="$2" tmp
  shift 2
  mkdir -p "$(dirname "$path")"
  [[ -f "$path" ]] || echo '{}' >"$path"
  tmp="$(mktemp)"
  if jq "$@" "$filter" "$path" >"$tmp"; then
    mv "$tmp" "$path"
  else
    rm -f "$tmp"
    die "jq failed on $path — left unchanged"
  fi
}

# The practice skills: skills/*/SKILL.md with category: practice.
practice_skills() {
  local f
  for f in "$SKILLS_SRC"/*/SKILL.md; do
    [[ -f "$f" ]] || continue
    grep -qx 'category: practice' "$f" && basename "$(dirname "$f")"
  done
  return 0
}

practice_json() {
  practice_skills | jq -R . | jq -sc .
}

rule_open()  { echo "<!-- $HARNESS_MARK:opencode-rule $1 -->"; }
rule_close() { echo "<!-- /$HARNESS_MARK:opencode-rule $1 -->"; }

# ─── Workspace map ───────────────────────────────────────────────────────────

write_workspace_map() {
  echo "── Workspace map ──"
  local mode
  if [[ -n "${BYRDE_WORKSPACE_MODE:-}" ]]; then
    mode="$BYRDE_WORKSPACE_MODE"
  else
    mode="$(workspace_declared_mode)"
  fi
  case "$mode" in
    mono | multi) ;;
    *) mode="mono"; [[ ${#SIBLING_REPOS[@]} -gt 0 ]] && mode="multi" ;;
  esac
  workspace_generate "$mode"
  echo "  ✓ ${WORKSPACE_FILE#"$ROOT"/} (mode: $mode)"
  echo ""
}

# ─── Rules ───────────────────────────────────────────────────────────────────

# OpenCode 2 reads AGENTS.md. Each rule is a fenced section; text outside the
# fences is yours. The fences differ from the Codex ones, so the other
# installer never removes a section that OpenCode reads.
install_rules() {
  echo "── Rules → AGENTS.md ──"
  local f name
  for f in "$RULES_SRC"/*.md; do
    [[ -f "$f" ]] || continue
    name="$(basename "$f" .md)"
    _harness_block_put "$ROOT/AGENTS.md" "$(rule_open "$name")" "$(rule_close "$name")" "$(harness_rule_body "$f")"
    echo "  ✓ $name"
  done
  echo ""
}

remove_rules() {
  local f name
  [[ -f "$ROOT/AGENTS.md" ]] || return 0
  for f in "$RULES_SRC"/*.md; do
    [[ -f "$f" ]] || continue
    name="$(basename "$f" .md)"
    [[ -f "$ROOT/AGENTS.md" ]] || break
    _harness_block_put "$ROOT/AGENTS.md" "$(rule_open "$name")" "$(rule_close "$name")" ""
  done
  echo "  ✓ removed the rule sections from AGENTS.md"
}

# ─── Settings: opencode.json ─────────────────────────────────────────────────

# Allow-all, and a deny for each practice skill as a skill: OpenCode also finds
# them in .agents/skills/, and the agent is the one to use. Ours are identified
# exactly, so a re-run replaces them and the user's own rules stay in place.
# The denies go last, so they win over the allow-all.
JQ_OURS='
  def ours($skills): (.action == "*" and .resource == "*" and .effect == "allow")
    or (.action == "skill" and .effect == "deny" and (.resource as $r | $skills | index($r)));
'

write_settings() {
  echo "── Settings → .opencode/opencode.json ──"
  local skills old
  skills="$(practice_json)"
  old="$(jq -c '.practiceSkills // []' "$STATE" 2>/dev/null || echo '[]')"
  json_edit "$CFG" "$JQ_OURS"'
    (($skills + $old) | unique) as $all
    | .["$schema"] = (.["$schema"] // "https://opencode.ai/config.json")
    | .permissions = (
        [{action: "*", resource: "*", effect: "allow"}]
        + [(.permissions // [])[] | select(ours($all) | not)]
        + [$skills[] | {action: "skill", resource: ., effect: "deny"}])
  ' --argjson skills "$skills" --argjson old "$old"
  echo "  ✓ permissions: allow every tool call; practice skills run as agents, not as skills"

  if workspace_has_github_remote; then
    # oauth: false — GitHub cannot do OAuth with dynamic client registration.
    # Without it, a missing token makes OpenCode wait for an OAuth flow, and
    # `opencode run` hangs before it prints anything.
    json_edit "$CFG" '
      .mcp = (.mcp // {}) | .mcp.servers = (.mcp.servers // {})
      | .mcp.servers.github = {type: "remote", url: $url, oauth: false,
          headers: {Authorization: "Bearer {env:GITHUB_PERSONAL_ACCESS_TOKEN}"}}
    ' --arg url "$GITHUB_MCP_URL"
    echo "  ✓ mcp: github (export GITHUB_PERSONAL_ACCESS_TOKEN=\"\$(gh auth token)\")"
  else
    echo "  – mcp: no github.com remote in the workspace map, so no GitHub server"
  fi
  echo ""
}

remove_settings() {
  [[ -f "$CFG" ]] || return 0
  local old
  old="$(jq -c '.practiceSkills // []' "$STATE" 2>/dev/null || echo '[]')"
  json_edit "$CFG" "$JQ_OURS"'
    (($old + $now) | unique) as $all
    | .permissions = [(.permissions // [])[] | select(ours($all) | not)]
    | (if .permissions == [] then del(.permissions) else . end)
    | (if .mcp.servers.github then del(.mcp.servers.github) else . end)
    | (if (.mcp.servers // null) == {} then del(.mcp.servers) else . end)
    | (if (.mcp // null) == {} then del(.mcp) else . end)
  ' --argjson old "$old" --argjson now "$(practice_json)"
  if [[ "$(jq -c 'del(.["$schema"])' "$CFG")" == "{}" ]]; then
    rm -f "$CFG"
  fi
  echo "  ✓ removed the permissions and the GitHub server from .opencode/opencode.json"
}

# ─── Plugin and memory ───────────────────────────────────────────────────────

install_plugin() {
  echo "── Plugin and memory ──"
  mkdir -p "$(dirname "$PLUGIN_DEST")" "$MEMORY_DIR"
  cp "$PLUGIN_SRC" "$PLUGIN_DEST"
  json_edit "$STATE" '
    .rulesDir = $rules | .skillsDir = $skills | .memoryDir = $memory | .practiceSkills = $practice
  ' --arg rules "$RULES_SRC" --arg skills "$SKILLS_SRC" --arg memory "$MEMORY_DIR" \
    --argjson practice "$(practice_json)"
  echo "  ✓ .opencode/plugins/byrde-agents.js — skill method and memory in each agent's"
  echo "    prompt, rules re-injected every ${BYRDE_RULES_REINJECT_EVERY:-12} tool calls"
  echo "  ✓ memory → ${MEMORY_DIR#"$ROOT"/}/ (git-tracked, shared with the team)"
  echo ""
}

# ─── Evaluation ──────────────────────────────────────────────────────────────

prepare_cache() {
  mkdir -p "$CACHE"
  # Ignored from inside, so a stray copy never reaches git.
  [[ -f "$CACHE/.gitignore" ]] || printf '*\n' >"$CACHE/.gitignore"
}

# The models OpenCode can use in this project, reduced to what scoring needs.
# BYRDE_OC_MODELS_FILE replaces the live call (tests, offline runs). Prints
# nothing and returns 1 when the list cannot be read.
fetch_models() {
  local out="$1" raw
  raw="$(mktemp "${TMPDIR:-/tmp}/byrde-models.XXXXXX")"
  if [[ -n "${BYRDE_OC_MODELS_FILE:-}" ]]; then
    cp "$BYRDE_OC_MODELS_FILE" "$raw"
  elif ! command -v "$OPENCODE_BIN" >/dev/null 2>&1 \
     || ! (cd "$ROOT" && perl -e 'alarm shift; exec @ARGV' 120 \
             "$OPENCODE_BIN" api --standalone GET /api/model >"$raw" 2>/dev/null); then
    rm -f "$raw"
    return 1
  fi
  # Provider settings (API keys) stay behind in $raw, which is deleted.
  if ! jq '[(if type == "array" then . else .data end)[]
        | select(.enabled != false and .status != "deprecated")
        | select((.capabilities.output // ["text"]) | index("text"))
        | {providerID, id, modelID: (.modelID // .id),
           variants: [(.variants // [])[] | .id],
           tools: (.capabilities.tools // false),
           input: (.capabilities.input // ["text"]),
           context: (.limit.context // 0),
           cost: [(.cost // [])[] | {input, output}]}]' "$raw" >"$out" 2>/dev/null; then
    rm -f "$raw"
    return 1
  fi
  rm -f "$raw"
}

fetch_catalog() {
  local out="$1"
  if [[ -n "${BYRDE_CATALOG_FILE:-}" ]]; then cp "$BYRDE_CATALOG_FILE" "$out"; return 0; fi
  curl -fsS --max-time 120 "$CATALOG_URL" -o "$out.tmp" 2>/dev/null && mv "$out.tmp" "$out" && return 0
  rm -f "$out.tmp"
  return 1
}

fetch_aa() {
  local out="$1"
  if [[ -n "${BYRDE_AA_FILE:-}" ]]; then cp "$BYRDE_AA_FILE" "$out"; return 0; fi
  [[ -n "${ARTIFICIAL_ANALYSIS_API_KEY:-}" ]] || return 1
  # The header goes in on stdin: never on disk, never in `ps`.
  if printf 'x-api-key: %s\n' "$ARTIFICIAL_ANALYSIS_API_KEY" \
       | curl -fsS --max-time 120 -H @- "$AA_URL" -o "$out.tmp" 2>/dev/null; then
    mv "$out.tmp" "$out"
    return 0
  fi
  rm -f "$out.tmp"
  echo "  ⚠ the Artificial Analysis API refused the request (check the key)" >&2
  return 1
}

evaluate_agents() {
  echo "── Agents: one per practice skill, each on its best model ──"
  prepare_cache
  local args=(run --skills "$SKILLS_SRC" --root "$ROOT" --state "$STATE")
  local models="$CACHE/models.json"
  if ! fetch_models "$models"; then
    echo "  ⚠ could not list OpenCode's models (is OpenCode 2 installed?) — every agent inherits"
    python3 "$EVALUATE_PY" "${args[@]}"
    echo ""
    return 0
  fi
  args+=(--models "$models")

  # OpenCode's built-in provider alone is a bare session: nothing to score.
  if [[ "$(jq '[.[].providerID | select(. != "opencode")] | length' "$models")" -gt 0 ]]; then
    if fetch_aa "$CACHE/aa.json"; then
      args+=(--aa "$CACHE/aa.json")
    elif [[ -s "$CACHE/aa.json" ]]; then
      echo "  ⚠ ARTIFICIAL_ANALYSIS_API_KEY is not set — reusing the benchmark data cached on" \
        "$(date -r "$CACHE/aa.json" +%Y-%m-%d)"
      args+=(--aa "$CACHE/aa.json")
    fi
    if fetch_catalog "$CACHE/catalog.json" || [[ -s "$CACHE/catalog.json" ]]; then
      args+=(--catalog "$CACHE/catalog.json")
    fi
  fi
  python3 "$EVALUATE_PY" "${args[@]}"
  echo ""
}

# ─── .gitignore ──────────────────────────────────────────────────────────────

strip_gitignore() {
  local gi="$ROOT/.gitignore"
  [[ -f "$gi" ]] || return 0
  sed -i '' "/^$GI_START\$/,/^$GI_END\$/d" "$gi"
  sed -i '' -e :a -e '/^[[:space:]]*$/{' -e '$d' -e N -e ba -e '}' "$gi" 2>/dev/null || true
}

# The generated files depend on this machine's providers and on .agents, so
# they stay out of git. memory/ is not listed: it is shared.
write_gitignore() {
  local gi="$ROOT/.gitignore" lines s
  lines=".opencode/plugins/byrde-agents.js"$'\n'".opencode/byrde-agents.json"$'\n'".opencode/.byrde/"
  for s in $(practice_skills); do lines="$lines"$'\n'".opencode/agents/$s.md"; done
  lines="$lines"$'\n'".worktrees/"$'\n'"$(basename "$WORKSPACE_FILE")"
  touch "$gi"
  strip_gitignore
  printf '\n%s\n%s\n%s\n' "$GI_START" "$lines" "$GI_END" >>"$gi"
  echo "  ✓ .gitignore: generated OpenCode files ignored"
}

# ─── Commands ────────────────────────────────────────────────────────────────

print_intro() {
  local b; b="$(bar)"
  echo "$b"
  echo "  $PROG_NAME · Byrde Agents  v$TOOL_VERSION"
  echo ""
  echo "  $1"
  echo ""
  printf '  %-16s %s\n' "Context Root" "$ROOT"
  printf '  %-16s %s\n' "Agents Root" "$AGENTS_ROOT"
  echo "$b"
  echo ""
}

install() {
  require_cmd jq
  require_cmd python3
  require_cmd git
  print_intro "Set up OpenCode: rules, practice skills as agents, permissions, memory, MCP."
  write_workspace_map
  install_rules
  write_settings
  install_plugin
  evaluate_agents
  write_gitignore
  local b; b="$(bar)"
  echo ""
  echo "$b"
  echo "  Done. Restart OpenCode to load the agents and the plugin."
  echo "  Re-score after a provider change:  .agents/scripts/opencode/init.sh evaluate"
  echo "  Add Fuel iX models:               .agents/scripts/opencode/setup-fuelix.sh"
  echo "  Undo:                             .agents/scripts/opencode/init.sh uninstall"
  echo "$b"
}

evaluate_cmd() {
  require_cmd jq
  require_cmd python3
  [[ -f "$STATE" ]] || die "OpenCode is not set up here yet: run .agents/scripts/opencode/init.sh first"
  print_intro "Re-score the models and re-pin each agent."
  evaluate_agents
  echo "  Restart OpenCode to load the new models."
}

uninstall() {
  require_cmd jq
  require_cmd python3
  print_intro "Remove what the OpenCode installer wrote. memory/ and your own settings stay."
  python3 "$EVALUATE_PY" clean --root "$ROOT" --state "$STATE"
  remove_settings
  rm -f "$PLUGIN_DEST"
  rmdir "$OC/plugins" 2>/dev/null || true
  rm -rf "$CACHE" "$STATE"
  rmdir "$OC" 2>/dev/null || true
  echo "  ✓ removed the plugin, its settings and the cached data"
  remove_rules
  strip_gitignore
  # A .gitignore that held only our block was ours.
  [[ -f "$ROOT/.gitignore" && ! -s "$ROOT/.gitignore" ]] && rm -f "$ROOT/.gitignore"
  echo "  ✓ removed the .gitignore block"
  # The map is shared with init.sh: keep it while that installer uses it.
  if [[ -f "$WORKSPACE_FILE" ]] && ! jq -e '(.harnesses // []) | length > 0' "$WORKSPACE_FILE" >/dev/null 2>&1; then
    rm -f "$WORKSPACE_FILE"
    echo "  ✓ removed ${WORKSPACE_FILE#"$ROOT"/}"
  fi
}

main() {
  case "${1:-}" in
    -h | --help | help)
      echo "$PROG_NAME · Byrde Agents v$TOOL_VERSION"
      echo ""
      echo "Sets up OpenCode 2: the practice skills become agents, each pinned to the"
      echo "model that suits its kind of work."
      echo ""
      echo "Usage:"
      echo "  cd /your/project && $0              # install, then evaluate"
      echo "  cd /your/project && $0 evaluate     # re-score the models only"
      echo "  cd /your/project && $0 uninstall    # remove what install wrote"
      echo ""
      echo "Environment:"
      echo "  ARTIFICIAL_ANALYSIS_API_KEY  Benchmark data for scoring (free key at"
      echo "                               https://artificialanalysis.ai/). Without it,"
      echo "                               the last download is reused, or agents inherit."
      echo "  BYRDE_RULES_REINJECT_EVERY   Re-inject the rules every N tool calls (default 12, 0 = off)."
      echo "  BYRDE_WORKSPACE_MODE         mono | multi — force the workspace flavour."
      exit 0
      ;;
  esac
  resolve_layout
  use_run_root
  set_paths
  case "${1:-}" in
    "") install ;;
    evaluate) evaluate_cmd ;;
    uninstall | remove) uninstall ;;
    *) die "unknown command: $1 (see --help)" ;;
  esac
}

main "$@"
