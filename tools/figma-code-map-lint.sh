#!/usr/bin/env bash
# Lint a project's Figma↔code component map (figma-code-map.json) — the free
# stand-in for Figma Code Connect maintained via figma-design-system.
#
# Project-agnostic: ships in the .agents toolkit and runs against whatever map
# the consuming repo keeps. Pure bash + jq (no Node, no python). Bash 3.2-safe.
#
# Two layers of checks:
#   1. Structural — validates the file against the canonical JSON Schema
#      (figma-code-map.schema.json, alongside this script), using a small
#      generic JSON-Schema-subset validator written in jq (the schema is the
#      single source of truth; this script does not restate its rules).
#   2. Semantic  — checks the map against the actual project:
#        • every components[].path exists on disk           (fail)
#        • components[].code names are unique                (fail)
#        • node ids look like Figma "<num>:<num>"            (fail, via schema)
#        • component-like sibling files missing an entry     (warn, heuristic)
#
# Usage:
#   cd /path/to/project && .agents/tools/figma-code-map-lint.sh [map.json]
#
# Defaults to ./figma-code-map.json. Exits non-zero if any check fails.
#
# Requires: jq

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCHEMA="$SCRIPT_DIR/figma-code-map.schema.json"

PROG_NAME="$(basename "${BASH_SOURCE[0]}")"
TOOL_VERSION="0.1.0"

# ─── Reporting ───────────────────────────────────────────────────────────────

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  C_GREEN=$'\033[32m'; C_RED=$'\033[31m'; C_YELLOW=$'\033[33m'; C_DIM=$'\033[90m'; C_RESET=$'\033[0m'
else
  C_GREEN=''; C_RED=''; C_YELLOW=''; C_DIM=''; C_RESET=''
fi

PASS=0; FAIL=0; WARN=0
pass() { printf '  %s✓%s %s\n' "$C_GREEN" "$C_RESET" "$*"; PASS=$((PASS+1)); }
fail() { printf '  %s✗%s %s\n' "$C_RED" "$C_RESET" "$*"; FAIL=$((FAIL+1)); }
warn() { printf '  %s⚠%s %s\n' "$C_YELLOW" "$C_RESET" "$*"; WARN=$((WARN+1)); }
info() { printf '  %s- %s%s\n' "$C_DIM" "$*" "$C_RESET"; }

die() { printf 'error: %s\n' "$*" >&2; exit 2; }

# ─── Args ────────────────────────────────────────────────────────────────────

MAP=""
for arg in "$@"; do
  case "$arg" in
    -h|--help)
      awk 'NR>1 && /^#/ {sub(/^# ?/,""); print; next} NR>1 {exit}' "${BASH_SOURCE[0]}"
      exit 0
      ;;
    -*) die "unknown option: $arg" ;;
    *)  MAP="$arg" ;;
  esac
done
MAP="${MAP:-./figma-code-map.json}"

command -v jq >/dev/null 2>&1 || die "missing required command: jq"
[[ -f "$SCHEMA" ]] || die "schema not found: $SCHEMA"
[[ -f "$MAP" ]] || die "map not found: $MAP (pass a path, or run from the project root)"

# Project-relative paths in the map resolve against the map file's directory.
BASE="$(cd "$(dirname "$MAP")" && pwd)"

bar="$(printf '%*s' 60 '' | tr ' ' '=')"
echo "$bar"
echo "  $PROG_NAME · Byrde Agents  v$TOOL_VERSION"
echo "  map:    $MAP"
echo "  schema: $(basename "$SCHEMA")"
echo "$bar"

# ─── 0. Valid JSON ───────────────────────────────────────────────────────────

echo ""
echo "JSON"
if ! jq empty "$MAP" 2>/tmp/fcm_jqerr; then
  fail "not valid JSON: $(tr '\n' ' ' </tmp/fcm_jqerr)"
  rm -f /tmp/fcm_jqerr
  echo ""; echo "$bar"; printf '  %sFAILED%s — fix JSON syntax before re-running.\n' "$C_RED" "$C_RESET"
  exit 1
fi
rm -f /tmp/fcm_jqerr
jq empty "$SCHEMA" 2>/dev/null || die "schema is not valid JSON: $SCHEMA"
pass "valid JSON"

# ─── 1. Structural — generic JSON-Schema-subset validator (in jq) ────────────

JQ_VALIDATOR='
def matches_type($t; $v):
  ($v|type) as $jt
  | if   $t=="integer" then ($jt=="number") and (($v|floor)==$v)
    elif $t=="number"  then $jt=="number"
    else $jt==$t end;

def validate($schema; $v; $path):
  ( if ($schema|has("type")) then
      (if ($schema.type|type)=="array" then $schema.type else [$schema.type] end) as $types
      | (if any($types[]; . as $tt | matches_type($tt; $v)) then []
         else ["\($path): expected type \($schema.type|tojson), got \($v|type)"] end)
    else [] end )
  + ( if ($schema|has("enum")) then
        (if ($schema.enum | index($v)) != null then []
         else ["\($path): \($v|tojson) not in enum \($schema.enum|tojson)"] end)
      else [] end )
  + ( if ($schema|has("const")) then
        (if $v == $schema.const then [] else ["\($path): expected \($schema.const|tojson)"] end)
      else [] end )
  + ( if ($schema|has("pattern")) and (($v|type)=="string") then
        (if ($v|test($schema.pattern)) then []
         else ["\($path): \($v|tojson) does not match pattern /\($schema.pattern)/"] end)
      else [] end )
  + ( if ($schema|has("required")) and (($v|type)=="object") then
        [ $schema.required[] as $r | select(($v|has($r))|not) | "\($path): missing required property \"\($r)\"" ]
      else [] end )
  + ( if ($schema|has("properties")) and (($v|type)=="object") then
        [ $schema.properties | to_entries[] | .key as $k
          | if ($v|has($k)) then validate(.value; $v[$k]; "\($path).\($k)") else [] end ] | add // []
      else [] end )
  + ( if ($schema|has("additionalProperties")) and (($v|type)=="object") then
        $schema.additionalProperties as $ap
        | ($schema.properties // {} | keys) as $known
        | [ $v | keys[] | select(. as $k | ($known|index($k))==null) ] as $extra
        | if   $ap == false        then [ $extra[] | "\($path): additional property \"\(.)\" not allowed" ]
          elif ($ap|type)=="object" then [ $extra[] | . as $k | validate($ap; $v[$k]; "\($path).\($k)") ] | add // []
          else [] end
      else [] end )
  + ( if ($schema|has("items")) and (($v|type)=="array") then
        [ range(0; ($v|length)) as $i | validate($schema.items; $v[$i]; "\($path)[\($i)]") ] | add // []
      else [] end ) ;

validate($schema[0]; $data[0]; "$")[]
'

echo ""
echo "Schema"
STRUCT_ERRORS="$(jq -rn --slurpfile schema "$SCHEMA" --slurpfile data "$MAP" "$JQ_VALIDATOR")"
if [[ -n "$STRUCT_ERRORS" ]]; then
  while IFS= read -r line; do
    [[ -n "$line" ]] && fail "$line"
  done <<< "$STRUCT_ERRORS"
else
  pass "conforms to schema"
fi

# ─── 2a. Semantic — component paths exist ────────────────────────────────────

echo ""
echo "Component paths"
MISSING=0
while IFS= read -r rel; do
  [[ -z "$rel" ]] && continue
  if [[ -f "$BASE/$rel" ]]; then
    :
  else
    fail "path does not exist: $rel"
    MISSING=$((MISSING+1))
  fi
done < <(jq -r '.components[]?.path // empty' "$MAP")
[[ "$MISSING" -eq 0 ]] && pass "all component paths exist"

# ─── 2b. Semantic — unique code names ────────────────────────────────────────

echo ""
echo "Unique code names"
DUPES="$(jq -r '[.components[]?.code] | group_by(.) | map(select(length>1)) | .[]? | "\(.[0]) (×\(length))"' "$MAP")"
if [[ -n "$DUPES" ]]; then
  while IFS= read -r d; do
    [[ -n "$d" ]] && fail "duplicate code component: $d"
  done <<< "$DUPES"
else
  pass "no duplicate code names"
fi

# ─── 2c. Semantic — coverage (heuristic, warn-only) ──────────────────────────
# Look in the directories that mapped components live in for sibling source
# files that have no entry. Excludes tests/stories/index/type/declaration files.
# Heuristic by nature (a project may legitimately not map every file), so warns.

echo ""
echo "Coverage (heuristic)"
MAPPED_LIST="$(mktemp)"; trap 'rm -f "$MAPPED_LIST"' EXIT
jq -r '.components[]?.path // empty' "$MAP" | sort -u > "$MAPPED_LIST"

UNMAPPED=0
DIRS="$(jq -r '.components[]?.path // empty | if test("/") then sub("/[^/]*$";"") else "." end' "$MAP" | sort -u)"
while IFS= read -r dir; do
  [[ -z "$dir" ]] && continue
  absdir="$BASE/$dir"
  [[ -d "$absdir" ]] || continue
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    name="$(basename "$f")"
    case "$name" in
      *.test.*|*.spec.*|*.stories.*|*.story.*|*.d.ts|index.*|*.types.ts|*.types.tsx) continue ;;
    esac
    rel="$dir/$f"; rel="${rel#./}"
    if ! grep -Fxq "$rel" "$MAPPED_LIST"; then
      warn "no map entry for: $rel"
      UNMAPPED=$((UNMAPPED+1))
    fi
  done < <(cd "$absdir" && find . -maxdepth 1 -type f \
              \( -name '*.tsx' -o -name '*.jsx' -o -name '*.ts' -o -name '*.js' -o -name '*.vue' -o -name '*.svelte' \) \
              | sed 's#^\./##' | sort)
done <<< "$DIRS"
[[ "$UNMAPPED" -eq 0 ]] && pass "every sibling source file is mapped"

# ─── Summary ─────────────────────────────────────────────────────────────────

echo ""
echo "$bar"
printf '  %s%d passed%s · %s%d warnings%s · %s%d failed%s\n' \
  "$C_GREEN" "$PASS" "$C_RESET" "$C_YELLOW" "$WARN" "$C_RESET" "$C_RED" "$FAIL" "$C_RESET"
echo "$bar"

[[ "$FAIL" -eq 0 ]]
