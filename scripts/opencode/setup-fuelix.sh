#!/usr/bin/env bash
# Add Fuel iX to OpenCode as a provider, with the models you choose.
#
# Fuel iX serves several model families behind one key, and each family takes a
# different API. So the models are split across three providers, one per API:
#
#   fuelix-anthropic  claude-*            @ai-sdk/anthropic (Messages API)
#   fuelix-openai     gpt-*, o<digit>*    @ai-sdk/openai (Responses API)
#   fuelix            everything else     @ai-sdk/openai-compatible (Chat Completions)
#
# The three providers belong to this script: a re-run replaces their model
# lists with the new choice. Then it re-runs the OpenCode evaluation, so every
# agent is re-scored against the new models.
#
# Run from the folder you open OpenCode in (the one that contains .agents):
#   cd /your/project && .agents/scripts/opencode/setup-fuelix.sh                  # choose models
#   cd /your/project && .agents/scripts/opencode/setup-fuelix.sh --models a,b,c   # no question
#   cd /your/project && .agents/scripts/opencode/setup-fuelix.sh uninstall
#
# Writes: .opencode/opencode.json — "providers" (merged, never replaced).
#
# Auth — no secrets on disk. The config names FUELIX_API_KEY; OpenCode reads it
# from the environment. This script sends it to Fuel iX on curl's stdin to
# list the models.
#
# Requires: jq, curl. Bash 3.2 (macOS) compatible.

set -euo pipefail

OC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_DIR="$(cd "$OC_DIR/.." && pwd)"
AGENTS_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../lib/layout.sh
. "$SCRIPT_DIR/lib/layout.sh"
# shellcheck source=../lib/workspace.sh
. "$SCRIPT_DIR/lib/workspace.sh"

FUELIX_URL="${BYRDE_FUELIX_URL:-https://api.fuelix.ai/v1}"
PROVIDERS='["fuelix-anthropic","fuelix-openai","fuelix"]'
PROG_NAME="opencode/$(basename "${BASH_SOURCE[0]}")"

die() {
  echo "error: $*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing required command: $1 (install it or add it to PATH)"
}

# Model ids Fuel iX serves, one per line. Models that cannot run an agent
# (images, speech, embeddings, moderation) are left out.
# BYRDE_FUELIX_MODELS_FILE replaces the live call (tests).
list_models() {
  local raw
  if [[ -n "${BYRDE_FUELIX_MODELS_FILE:-}" ]]; then
    raw="$(cat "$BYRDE_FUELIX_MODELS_FILE")"
  else
    [[ -n "${FUELIX_API_KEY:-}" ]] || die "set FUELIX_API_KEY to your Fuel iX API key"
    raw="$(printf 'Authorization: Bearer %s\n' "$FUELIX_API_KEY" \
      | curl -fsS --max-time 60 -H @- "$FUELIX_URL/models")" \
      || die "Fuel iX refused the request to $FUELIX_URL/models (check FUELIX_API_KEY)"
  fi
  jq -r '(.data // .)[] | .id' <<<"$raw" \
    | grep -viE 'dall-e|whisper|tts|embed|image|moderation|rerank|transcribe|audio|realtime|speech' \
    | sort -u
}

# The models already configured, comma-separated.
current_models() {
  [[ -f "$CFG" ]] || return 0
  jq -r --argjson p "$PROVIDERS" '[.providers // {} | to_entries[] | select(.key as $k | $p | index($k))
    | .value.models // {} | keys[]] | sort | join(",")' "$CFG"
}

# Resolve a comma/space list of names or numbers against the available ids.
pick() {
  local list="$1" choice="$2" word i id out=""
  for word in $(printf '%s' "$choice" | tr ',' ' '); do
    if [[ "$word" =~ ^[0-9]+$ ]]; then
      id="$(sed -n "${word}p" <<<"$list")"
      [[ -n "$id" ]] || { echo "  ⚠ no model numbered $word — ignored" >&2; continue; }
    elif grep -qxF "$word" <<<"$list"; then
      id="$word"
    else
      echo "  ⚠ Fuel iX does not serve '$word' — ignored" >&2
      continue
    fi
    out="$out,$id"
  done
  printf '%s' "${out#,}" | tr ',' '\n' | awk 'NF && !seen[$0]++' | paste -sd, -
}

choose() {
  local list="$1" given="$2" current ans choice
  if [[ -n "$given" ]]; then
    choice="$(pick "$list" "$given")"
    [[ -n "$choice" ]] || die "none of '$given' is a Fuel iX model"
    echo "$choice"
    return
  fi
  current="$(current_models)"
  [[ -t 0 ]] || { [[ -n "$current" ]] && { echo "$current"; return; }; die "no terminal to ask on: pass --models a,b,c"; }
  {
    echo "  Fuel iX serves these models:"
    echo ""
    nl -w4 -s') ' <<<"$list" | sed 's/^/  /'
    echo ""
  } >&2
  while :; do
    read -r -p "  Numbers or names, comma-separated${current:+ [Enter keeps: $current]}: " ans </dev/tty || ans=""
    if [[ -z "$ans" && -n "$current" ]]; then echo "$current"; return; fi
    choice="$(pick "$list" "$ans")"
    [[ -n "$choice" ]] && { echo "$choice"; return; }
    echo "  Pick at least one." >&2
  done
}

write_providers() {
  local models="$1" tmp
  mkdir -p "$(dirname "$CFG")"
  [[ -f "$CFG" ]] || echo '{}' >"$CFG"
  tmp="$(mktemp)"
  jq --arg url "$FUELIX_URL" --arg models "$models" --argjson p "$PROVIDERS" '
    def family: if test("^claude") then "fuelix-anthropic"
                elif test("^(gpt|o[0-9])") then "fuelix-openai"
                else "fuelix" end;
    def provider($name; $pkg; $extra):
      {name: $name, package: $pkg, env: ["FUELIX_API_KEY"], settings: {baseURL: $url}} + $extra;
    ($models | split(",") | map(select(. != ""))) as $ids
    | {
        "fuelix-anthropic": provider("Fuel iX (Anthropic API)"; "@ai-sdk/anthropic";
          {headers: {Authorization: "Bearer {env:FUELIX_API_KEY}"}}),
        "fuelix-openai": provider("Fuel iX (OpenAI Responses API)"; "@ai-sdk/openai"; {}),
        "fuelix": provider("Fuel iX (Chat Completions API)"; "@ai-sdk/openai-compatible"; {})
      } as $defs
    | .["$schema"] = (.["$schema"] // "https://opencode.ai/config.json")
    | .providers = ((.providers // {}) | with_entries(select(.key as $k | $p | index($k) | not)))
    | reduce $ids[] as $id (.;
        ($id | family) as $f
        | .providers[$f] = (.providers[$f] // $defs[$f])
        | .providers[$f].models[$id] = {name: ($id + " (Fuel iX)")})
  ' "$CFG" >"$tmp" || { rm -f "$tmp"; die "jq failed on $CFG — left unchanged"; }
  mv "$tmp" "$CFG"
}

remove_providers() {
  [[ -f "$CFG" ]] || return 0
  local tmp
  tmp="$(mktemp)"
  jq --argjson p "$PROVIDERS" '
    .providers = ((.providers // {}) | with_entries(select(.key as $k | $p | index($k) | not)))
    | (if .providers == {} then del(.providers) else . end)
  ' "$CFG" >"$tmp" || { rm -f "$tmp"; die "jq failed on $CFG — left unchanged"; }
  mv "$tmp" "$CFG"
  if [[ "$(jq -c 'del(.["$schema"])' "$CFG")" == "{}" ]]; then rm -f "$CFG"; fi
}

# Re-score the agents, when the OpenCode installer has run here.
reevaluate() {
  if [[ -f "$WORKSPACE_ROOT/.opencode/byrde-agents.json" ]]; then
    echo ""
    "$OC_DIR/init.sh" evaluate
  fi
}

main() {
  local given="" args=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --models) given="${2:-}"; shift 2 || shift ;;
      --models=*) given="${1#*=}"; shift ;;
      *) args+=("$1"); shift ;;
    esac
  done
  set -- ${args[@]+"${args[@]}"}

  case "${1:-}" in
    -h | --help | help)
      echo "$PROG_NAME · Byrde Agents"
      echo ""
      echo "Adds Fuel iX to OpenCode as a provider, with the models you choose."
      echo ""
      echo "Usage:"
      echo "  cd /your/project && $0                    # list the models and choose"
      echo "  cd /your/project && $0 --models a,b,c     # these models, no question"
      echo "  cd /your/project && $0 uninstall          # remove the Fuel iX providers"
      echo ""
      echo "Environment:"
      echo "  FUELIX_API_KEY  Your Fuel iX API key. OpenCode reads it at run time."
      exit 0
      ;;
  esac

  require_cmd jq
  resolve_layout
  CFG="$WORKSPACE_ROOT/.opencode/opencode.json"

  case "${1:-}" in
    uninstall | remove)
      remove_providers
      echo "  ✓ removed the Fuel iX providers from .opencode/opencode.json"
      reevaluate
      ;;
    "")
      require_cmd curl
      local list models
      list="$(list_models)"
      [[ -n "$list" ]] || die "Fuel iX listed no models"
      models="$(choose "$list" "$given")"
      write_providers "$models"
      echo "  ✓ .opencode/opencode.json — Fuel iX models: ${models//,/, }"
      [[ -n "${FUELIX_API_KEY:-}" ]] || echo "  ⚠ export FUELIX_API_KEY before you start OpenCode"
      reevaluate
      ;;
    *) die "unknown command: $1 (see --help)" ;;
  esac
}

main "$@"
