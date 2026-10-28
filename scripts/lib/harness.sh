#!/usr/bin/env bash
# Byrde Agents — harness adapters (shared lib).
#
# One source for every asset, adapted to each agent harness at install time:
#
#   claude       Claude Code
#   cursor       Cursor
#   codex        OpenAI Codex
#   copilot      GitHub Copilot (VS Code agent mode, CLI, coding agent)
#   antigravity  Google Antigravity
#
# The scripts never write a harness path themselves. They call the adapters
# below, once per selected harness, so a new harness is one more case arm here.
#
# WHERE EACH ASSET GOES
#
#   asset   claude                cursor             codex                copilot                             antigravity
#   rules   .claude/rules/*.md    .cursor/rules/*.mdc AGENTS.md (block)   .github/instructions/*.instructions.md  .agents/rules/*.md (native)
#   skills  .claude/skills/       .agents/skills/    .agents/skills/      .agents/skills/                     .agents/skills/
#   mcp     .mcp.json             .cursor/mcp.json   .codex/config.toml   .vscode/mcp.json                    .agents/mcp_config.json
#   hooks   .claude/settings.json .cursor/hooks.json .codex/hooks.json    .github/hooks/byrde-agents.json     (none — see below)
#
# `.agents/` IS THE SHARED FOLDER. Cursor, Codex, Copilot and Antigravity all
# read `.agents/skills/` natively, and Antigravity also reads `.agents/rules/`.
# In a mono install that folder is this checkout, so the practice skills and
# rules are already in place for them and copying would only load them twice.
# Every copy below is skipped when its destination resolves to its source.
#
# Rule SOURCE format: Markdown with a small frontmatter block —
#
#   ---
#   description: <one line>
#   trigger: always_on        # Antigravity reads the source files as-is
#   ---
#
# Each harness gets the body under its own frontmatter (or none, for Claude).
#
# Gaps, on purpose:
#   - Antigravity hooks: its PostToolUse cannot add context, and IDE hooks are
#     reported not to fire. No hook is written for it.
#   - Antigravity MCP has no env-var expansion, so a server that authenticates
#     with a bearer token from the environment is skipped rather than written
#     with a literal secret.
#
# Requires jq. Compatible with Bash 3.2 (macOS): no associative arrays.

HARNESS_ALL="claude cursor codex copilot antigravity"
HARNESS_DEFAULT="claude"

_HARNESS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_HARNESS_AGENTS_ROOT="$(cd "$_HARNESS_LIB_DIR/../.." && pwd)"
HARNESS_HOOK_SCRIPT="$_HARNESS_AGENTS_ROOT/scripts/hooks/reinject-rules.sh"

# Marker that identifies every block and entry these adapters own. A hook entry
# is ours when its command carries the marker or runs the re-injection script.
HARNESS_MARK="byrde-agents"
_HARNESS_JQ_OURS='def ours: (. // "") as $c | ($c | contains("byrde-agents")) or ($c | contains("reinject-rules.sh"));' 

# ─── Selection ───────────────────────────────────────────────────────────────

harness_label() {
  case "$1" in
    claude)      echo "Claude Code" ;;
    cursor)      echo "Cursor" ;;
    codex)       echo "OpenAI Codex" ;;
    copilot)     echo "GitHub Copilot" ;;
    antigravity) echo "Google Antigravity" ;;
    *)           echo "$1" ;;
  esac
}

harness_is_known() {
  case " $HARNESS_ALL " in *" $1 "*) return 0 ;; esac
  return 1
}

# Normalise a user list ("Claude, cursor 3 all") to known ids in canonical
# order, space-separated. Numbers index HARNESS_ALL from 1. Unknown words are
# reported on stderr and dropped.
harness_parse() {
  local raw word picked="" i h
  raw="$(printf '%s' "$*" | tr ',[:upper:]' ' [:lower:]')"
  for word in $raw; do
    case "$word" in
      all | '*') picked="$HARNESS_ALL"; continue ;;
    esac
    if [[ "$word" =~ ^[0-9]+$ ]]; then
      i=0
      for h in $HARNESS_ALL; do
        i=$((i + 1))
        [[ "$i" -eq "$word" ]] && { picked="$picked $h"; continue 2; }
      done
      echo "  ⚠ no harness numbered $word — ignored" >&2
      continue
    fi
    if harness_is_known "$word"; then
      picked="$picked $word"
    else
      echo "  ⚠ unknown harness '$word' — ignored (known: $HARNESS_ALL)" >&2
    fi
  done
  local out=""
  for h in $HARNESS_ALL; do
    case " $picked " in *" $h "*) out="$out $h" ;; esac
  done
  echo "${out# }"
}

# The known harnesses recorded in the workspace map, or nothing. The map sits
# next to the .agents checkout (see lib/workspace.sh) when the caller has not
# loaded it. Ids this version no longer knows (an old "opencode") are dropped.
harness_saved() {
  local map="${WORKSPACE_FILE:-$(cd "$_HARNESS_AGENTS_ROOT/.." && pwd)/.workspace.agents.json}" raw
  [[ -n "$map" && -f "$map" ]] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  raw="$(jq -r '(.harnesses // []) | join(" ")' "$map" 2>/dev/null || true)"
  [[ -n "$raw" ]] && harness_parse "$raw" 2>/dev/null
  return 0
}

# The harnesses to install for: $BYRDE_HARNESSES > the workspace map > default.
# init.sh is the only place that asks; the setup scripts follow its answer.
harness_selected() {
  local sel=""
  [[ -n "${BYRDE_HARNESSES:-}" ]] && sel="$(harness_parse "$BYRDE_HARNESSES" 2>/dev/null)"
  [[ -z "$sel" ]] && sel="$(harness_saved)"
  [[ -z "$sel" ]] && sel="$HARNESS_DEFAULT"
  echo "$sel"
}

harness_unselected() {
  local sel h out=""
  sel=" $(harness_selected) "
  for h in $HARNESS_ALL; do
    case "$sel" in *" $h "*) ;; *) out="$out $h" ;; esac
  done
  echo "${out# }"
}

harness_has() {
  case " $(harness_selected) " in *" $1 "*) return 0 ;; esac
  return 1
}

# Record the selection in the workspace map. workspace_generate preserves it.
harness_save() {
  local list="$1" map="${WORKSPACE_FILE:-$(cd "$_HARNESS_AGENTS_ROOT/.." && pwd)/.workspace.agents.json}" tmp
  [[ -n "$map" && -f "$map" ]] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  tmp="$(mktemp)"
  if jq --arg l "$list" '.harnesses = ($l | split(" ") | map(select(. != "")))' "$map" >"$tmp"; then
    mv "$tmp" "$map"
  else
    rm -f "$tmp"
  fi
}

# ─── Small helpers ───────────────────────────────────────────────────────────

# Same directory or file after resolving symlinks? Missing paths are never equal.
_harness_same_path() {
  [[ -e "$1" && -e "$2" ]] || return 1
  local a b
  if [[ -d "$1" ]]; then a="$(cd "$1" && pwd -P)"; else a="$(cd "$(dirname "$1")" && pwd -P)/$(basename "$1")"; fi
  if [[ -d "$2" ]]; then b="$(cd "$2" && pwd -P)"; else b="$(cd "$(dirname "$2")" && pwd -P)/$(basename "$2")"; fi
  [[ "$a" == "$b" ]]
}

# Print the frontmatter value of a key ("" when absent).
_harness_fm() {
  awk -v k="$2" '
    NR == 1 && $0 != "---" { exit }
    NR == 1 { next }
    $0 == "---" { exit }
    index($0, k ":") == 1 { sub("^" k ":[[:space:]]*", ""); print; exit }
  ' "$1"
}

# Print the body below the frontmatter, without leading blank lines.
harness_rule_body() {
  awk '
    NR == 1 && $0 == "---" { fm = 1; next }
    fm && $0 == "---" { fm = 0; next }
    fm { next }
    !started && /^[[:space:]]*$/ { next }
    { started = 1; print }
  ' "$1"
}

# Apply a jq filter to a JSON file in place, creating it from `{}` when absent.
# Leaves an unparseable file untouched. Extra args go to jq before the filter.
_harness_jq_edit() {
  local path="$1" filter="$2" tmp
  shift 2
  mkdir -p "$(dirname "$path")"
  [[ -f "$path" ]] || echo '{}' >"$path"
  tmp="$(mktemp)"
  if jq "$@" "$filter" "$path" >"$tmp" 2>/dev/null; then
    mv "$tmp" "$path"
  else
    rm -f "$tmp"
    echo "  ⚠ jq failed on $path — left unchanged" >&2
    return 1
  fi
}

# Delete a JSON file when it has become `{}` (or only `version`), and its
# folder when that is now empty — unless the folder is <keep> (the root).
_harness_prune_json() {
  local path="$1" keep="${2:-}" dir
  [[ -f "$path" ]] || return 0
  if [[ "$(jq -c 'del(.version)' "$path" 2>/dev/null)" == "{}" ]]; then
    rm -f "$path"
    dir="$(dirname "$path")"
    [[ -n "$keep" ]] && _harness_same_path "$dir" "$keep" && return 0
    rmdir "$dir" 2>/dev/null || true
  fi
  return 0
}

# Replace (or drop, with empty content) a marked block in a text file. Blocks are
# fenced by "<open>" / "<close>" lines. The file is removed if nothing else is
# left in it.
_harness_block_put() {
  local path="$1" open="$2" close="$3" content="$4" tmp
  mkdir -p "$(dirname "$path")"
  [[ -f "$path" ]] || : >"$path"
  tmp="$(mktemp)"
  # Blank lines are held back until the next line is known: the ones right
  # before a block are its separator and go with it, and trailing ones are
  # dropped, as are leading ones. Otherwise every re-run would leave one more
  # blank line behind.
  awk -v o="$open" -v c="$close" '
    $0 == o { skip = 1; blanks = 0; next }
    skip && $0 == c { skip = 0; next }
    skip { next }
    /^[[:space:]]*$/ { if (started) blanks++; next }
    { while (blanks > 0) { print ""; blanks-- } started = 1; print }
  ' "$path" >"$tmp"
  if [[ -n "$content" ]]; then
    { [[ -s "$tmp" ]] && echo ""; printf '%s\n%s\n%s\n' "$open" "$content" "$close"; } >>"$tmp"
  fi
  if [[ -s "$tmp" ]]; then
    mv "$tmp" "$path"
  else
    rm -f "$tmp" "$path"
  fi
}

# ─── Rules ───────────────────────────────────────────────────────────────────

# Where a harness keeps a rule file, relative to the root ("" = no per-rule file).
harness_rule_path() {
  local h="$1" name="$2"
  case "$h" in
    claude)      echo ".claude/rules/$name.md" ;;
    cursor)      echo ".cursor/rules/$name.mdc" ;;
    copilot)     echo ".github/instructions/$name.instructions.md" ;;
    antigravity) echo ".agents/rules/$name.md" ;;
    codex)       echo "" ;;
  esac
}

# AGENTS.md carries the rules for Codex. A section stays while Codex is
# selected; HARNESS_PURGE=1 (uninstall) removes it anyway.
_harness_agents_md_wanted() {
  [[ "${HARNESS_PURGE:-}" == "1" ]] && return 1
  harness_has codex
}

_harness_codex_open()  { echo "<!-- $HARNESS_MARK:rule $1 -->"; }
_harness_codex_close() { echo "<!-- /$HARNESS_MARK:rule $1 -->"; }

# Install one rule (a source .md) for one harness under <root>.
harness_rule_install() {
  local root="$1" h="$2" src="$3" name desc body dest
  name="$(basename "$src" .md)"
  desc="$(_harness_fm "$src" description)"
  body="$(harness_rule_body "$src")"
  case "$h" in
    claude)
      dest="$root/.claude/rules/$name.md"
      mkdir -p "$(dirname "$dest")"
      printf '%s\n' "$body" >"$dest"
      ;;
    cursor)
      dest="$root/.cursor/rules/$name.mdc"
      mkdir -p "$(dirname "$dest")"
      printf -- '---\ndescription: %s\nglobs: ["**/*"]\nalwaysApply: true\n---\n\n%s\n' "$desc" "$body" >"$dest"
      ;;
    copilot)
      dest="$root/.github/instructions/$name.instructions.md"
      mkdir -p "$(dirname "$dest")"
      printf -- '---\ndescription: %s\napplyTo: "**"\n---\n\n%s\n' "$desc" "$body" >"$dest"
      ;;
    antigravity)
      # The checkout's own rules/ is read natively. Anything else (a rule from
      # outside the checkout) goes to the legacy .agent/rules/,
      # which Antigravity still reads, so the shared checkout stays clean.
      if _harness_same_path "$root/.agents/rules/$name.md" "$src"; then
        return 0
      fi
      dest="$root/.agent/rules/$name.md"
      mkdir -p "$(dirname "$dest")"
      printf -- '---\ntrigger: always_on\ndescription: %s\n---\n\n%s\n' "$desc" "$body" >"$dest"
      ;;
    codex)
      # Codex reads one AGENTS.md per directory and nothing else, so each rule
      # is a fenced section inside it.
      # Anything outside the fences is yours.
      _harness_block_put "$root/AGENTS.md" "$(_harness_codex_open "$name")" \
        "$(_harness_codex_close "$name")" "$body"
      ;;
  esac
}

harness_rule_remove() {
  local root="$1" h="$2" name="$3"
  case "$h" in
    claude)      rm -f "$root/.claude/rules/$name.md"; rmdir "$root/.claude/rules" 2>/dev/null || true ;;
    cursor)      rm -f "$root/.cursor/rules/$name.mdc" "$root/.cursor/rules/$name.md"; rmdir "$root/.cursor/rules" 2>/dev/null || true ;;
    copilot)     rm -f "$root/.github/instructions/$name.instructions.md"; rmdir "$root/.github/instructions" "$root/.github" 2>/dev/null || true ;;
    antigravity) rm -f "$root/.agent/rules/$name.md"; rmdir "$root/.agent/rules" "$root/.agent" 2>/dev/null || true ;;
    codex)
      _harness_agents_md_wanted && return 0
      [[ -f "$root/AGENTS.md" ]] && _harness_block_put "$root/AGENTS.md" \
        "$(_harness_codex_open "$name")" "$(_harness_codex_close "$name")" ""
      ;;
  esac
  return 0
}

# Human-readable destination for a rule, for install logs.
harness_rule_where() {
  local h="$1" name="$2"
  case "$h" in
    codex)       echo "AGENTS.md (section $name)" ;;
    antigravity) echo ".agents/rules/$name.md (native)" ;;
    *)           harness_rule_path "$h" "$name" ;;
  esac
}

# ─── Skills ──────────────────────────────────────────────────────────────────

# Where a harness reads project skills, relative to the root. Everything except
# Claude reads the shared .agents/skills/ (see the header).
harness_skills_dir() {
  case "$1" in
    claude) echo ".claude/skills" ;;
    *)      echo ".agents/skills" ;;
  esac
}

# Mirror a skill directory into a harness's skills dir under <root>. A no-op
# when the destination is the source itself.
harness_skill_install() {
  local root="$1" h="$2" src="$3" name dir
  name="$(basename "$src")"
  dir="$root/$(harness_skills_dir "$h")"
  # Older installs mirrored into .cursor/skills/; Cursor now reads .agents/.
  if [[ "$h" == "cursor" ]]; then rm -rf "${root:?}/.cursor/skills/$name"; rmdir "$root/.cursor/skills" 2>/dev/null || true; fi
  _harness_same_path "$dir/$name" "$src" && return 0
  mkdir -p "$dir"
  rm -rf "${dir:?}/$name"
  cp -R "$src" "$dir/$name"
}

# Remove a skill mirror. Never removes the source: when the harness reads the
# source in place there is nothing of ours to remove.
harness_skill_remove() {
  local root="$1" h="$2" name="$3" src="${4:-}" dir
  dir="$root/$(harness_skills_dir "$h")"
  if [[ "$h" == "cursor" ]]; then rm -rf "${root:?}/.cursor/skills/$name"; rmdir "$root/.cursor/skills" 2>/dev/null || true; fi
  if [[ -n "$src" ]] && _harness_same_path "$dir/$name" "$src"; then
    return 0
  fi
  # The checkout's own skills/ is source, not a mirror.
  if _harness_same_path "$dir" "$_HARNESS_AGENTS_ROOT/skills" \
     && git -C "$_HARNESS_AGENTS_ROOT" ls-files --error-unmatch "skills/$name" >/dev/null 2>&1; then
    return 0
  fi
  rm -rf "${dir:?}/$name"
  rmdir "$dir" 2>/dev/null || true
  return 0
}

harness_skill_where() {
  local h="$1" name="$2"
  echo "$(harness_skills_dir "$h")/$name"
}

# ─── MCP servers ─────────────────────────────────────────────────────────────
#
# A server is described once, as neutral JSON:
#
#   { "type": "http" | "sse" | "stdio",
#     "url": "...",                       # http / sse
#     "command": "...", "args": [...], "env": {...},   # stdio
#     "bearerEnv": "VAR",                 # optional: Authorization: Bearer $VAR
#     "headersHelper": "/abs/script" }    # optional: Claude Code only
#
# and rendered per harness. Claude prefers headersHelper over bearerEnv, because
# it fetches the token live and nothing is kept in the environment.

harness_mcp_file() {
  case "$1" in
    claude)      echo ".mcp.json" ;;
    cursor)      echo ".cursor/mcp.json" ;;
    codex)       echo ".codex/config.toml" ;;
    copilot)     echo ".vscode/mcp.json" ;;
    antigravity) echo ".agents/mcp_config.json" ;;
  esac
}

# Render the neutral spec to one harness's server entry (JSON harnesses only).
_harness_mcp_render() {
  local h="$1" spec="$2"
  jq -c --arg h "$h" '
    . as $s
    | (if $s.bearerEnv then {Authorization: ("Bearer ${env:" + $s.bearerEnv + "}")} else null end) as $envHdr
    | if $s.type == "stdio" then
        {command: $s.command}
        + (if $s.args then {args: $s.args} else {} end)
        + (if $s.env then {env: $s.env} else {} end)
        + (if $h == "copilot" then {type: "stdio"} else {} end)
      elif $h == "claude" then
        {type: $s.type, url: $s.url}
        + (if $s.headersHelper then {headersHelper: $s.headersHelper}
           elif $s.bearerEnv then {headers: {Authorization: ("Bearer ${" + $s.bearerEnv + "}")}}
           else {} end)
      elif $h == "cursor" then
        {url: $s.url} + (if $envHdr then {headers: $envHdr} else {} end)
      elif $h == "copilot" then
        {type: $s.type, url: $s.url} + (if $envHdr then {headers: $envHdr} else {} end)
      elif $h == "antigravity" then
        {serverUrl: $s.url}
      else empty end
  ' <<<"$spec"
}

# Render the spec as a TOML table for Codex.
_harness_mcp_toml() {
  local name="$1" spec="$2"
  jq -r --arg n "$name" '
    def q: tojson;
    def key: if test("^[A-Za-z0-9_-]+$") then . else tojson end;
    "[mcp_servers.\($n | key)]",
    (if .type == "stdio" then
       "command = \(.command | q)",
       (if .args then "args = [\(.args | map(q) | join(", "))]" else empty end),
       (if .env then "env = { \(.env | to_entries | map("\(.key | key) = \(.value | q)") | join(", ")) }" else empty end)
     else
       "url = \(.url | q)",
       (if .bearerEnv then "bearer_token_env_var = \(.bearerEnv | q)" else empty end)
     end)
  ' <<<"$spec"
}

_harness_codex_mcp_open()  { echo "# >>> $HARNESS_MARK mcp:$1"; }
_harness_codex_mcp_close() { echo "# <<< $HARNESS_MARK mcp:$1"; }

# Register server <name> for one harness under <root>. Returns 2 when the
# harness cannot carry this server (and says why).
harness_mcp_put() {
  local root="$1" h="$2" name="$3" spec="$4" file entry
  file="$root/$(harness_mcp_file "$h")"
  case "$h" in
    codex)
      _harness_block_put "$file" "$(_harness_codex_mcp_open "$name")" \
        "$(_harness_codex_mcp_close "$name")" "$(_harness_mcp_toml "$name" "$spec")"
      ;;
    antigravity)
      if [[ "$(jq -r '.type != "stdio" and (.bearerEnv // "") != ""' <<<"$spec")" == "true" ]]; then
        echo "  ⚠ Antigravity: skipped $name — its MCP config cannot read a token from the" >&2
        echo "    environment, and this installer does not write secrets to disk." >&2
        return 2
      fi
      entry="$(_harness_mcp_render "$h" "$spec")"
      _harness_jq_edit "$file" '.mcpServers = (.mcpServers // {}) | .mcpServers[$n] = $e' \
        --arg n "$name" --argjson e "$entry"
      ;;
    copilot)
      entry="$(_harness_mcp_render "$h" "$spec")"
      _harness_jq_edit "$file" '.servers = (.servers // {}) | .servers[$n] = $e' \
        --arg n "$name" --argjson e "$entry"
      ;;
    claude | cursor)
      entry="$(_harness_mcp_render "$h" "$spec")"
      _harness_jq_edit "$file" '.mcpServers = (.mcpServers // {}) | .mcpServers[$n] = $e' \
        --arg n "$name" --argjson e "$entry"
      ;;
  esac
}

harness_mcp_remove() {
  local root="$1" h="$2" name="$3" file
  file="$root/$(harness_mcp_file "$h")"
  [[ -f "$file" ]] || return 0
  case "$h" in
    codex)
      _harness_block_put "$file" "$(_harness_codex_mcp_open "$name")" \
        "$(_harness_codex_mcp_close "$name")" ""
      rmdir "$root/.codex" 2>/dev/null || true
      ;;
    copilot)
      jq -e --arg n "$name" '.servers[$n]' "$file" >/dev/null 2>&1 || return 0
      _harness_jq_edit "$file" 'del(.servers[$n]) | if .servers == {} then del(.servers) else . end' --arg n "$name"
      _harness_prune_json "$file" "$root"
      ;;
    *)
      jq -e --arg n "$name" '.mcpServers[$n]' "$file" >/dev/null 2>&1 || return 0
      _harness_jq_edit "$file" 'del(.mcpServers[$n]) | if .mcpServers == {} then del(.mcpServers) else . end' --arg n "$name"
      # .agents/ is the shared checkout: never remove the folder itself.
      _harness_prune_json "$file" "$root"
      ;;
  esac
  return 0
}

# Is server <name> registered for this harness?
harness_mcp_has() {
  local root="$1" h="$2" name="$3" file
  file="$root/$(harness_mcp_file "$h")"
  [[ -f "$file" ]] || return 1
  case "$h" in
    codex)   grep -qxF "$(_harness_codex_mcp_open "$name")" "$file" ;;
    copilot) jq -e --arg n "$name" '.servers[$n]' "$file" >/dev/null 2>&1 ;;
    *)       jq -e --arg n "$name" '.mcpServers[$n]' "$file" >/dev/null 2>&1 ;;
  esac
}

# ─── Hooks ───────────────────────────────────────────────────────────────────
#
# Two hooks are adapted, both owned by init.sh:
#
#   reinject  after each tool call, re-assert the rules (reinject-rules.sh,
#             which answers in the shape each harness reads)
#   allow     before each tool call, approve it with no prompt
#
# Claude Code's are written by init.sh itself (settings.json carries more than
# hooks). The others are written here.

harness_hook_file() {
  case "$1" in
    claude)  echo ".claude/settings.json" ;;
    cursor)  echo ".cursor/hooks.json" ;;
    codex)   echo ".codex/hooks.json" ;;
    copilot) echo ".github/hooks/$HARNESS_MARK.json" ;;
    *)       echo "" ;;
  esac
}

harness_supports_hooks() {
  case "$1" in claude | cursor | codex | copilot) return 0 ;; esac
  return 1
}

# The command line for the re-injection hook, for one harness.
harness_reinject_cmd() {
  printf '"%s" --harness %s' "$HARNESS_HOOK_SCRIPT" "$1"
}

# The command line for the allow-all hook, for one harness. Each prints the
# decision in the shape that harness's pre-tool hook reads.
harness_allow_cmd() {
  case "$1" in
    cursor)  echo "echo '{\"permission\":\"allow\",\"$HARNESS_MARK\":\"allow-all\"}'" ;;
    codex)   echo "echo '{\"hookSpecificOutput\":{\"hookEventName\":\"PreToolUse\",\"permissionDecision\":\"allow\",\"permissionDecisionReason\":\"$HARNESS_MARK allow-all auto-approve\"}}'" ;;
    copilot) echo "echo '{\"permissionDecision\":\"allow\",\"permissionDecisionReason\":\"$HARNESS_MARK allow-all auto-approve\"}'" ;;
  esac
}

# Install both hooks for cursor / codex / copilot.
harness_hooks_install() {
  local root="$1" h="$2" file reinject allow
  file="$root/$(harness_hook_file "$h")"
  reinject="$(harness_reinject_cmd "$h")"
  allow="$(harness_allow_cmd "$h")"
  case "$h" in
    cursor)
      _harness_jq_edit "$file" "$_HARNESS_JQ_OURS"'
        .version = (.version // 1) | .hooks = (.hooks // {})
        | .hooks.postToolUse = ([(.hooks.postToolUse // [])[] | select(.command | ours | not)]
                                + [{command: $r}])
        | .hooks.preToolUse  = ([(.hooks.preToolUse  // [])[] | select(.command | ours | not)]
                                + [{command: $a}])
      ' --arg r "$reinject" --arg a "$allow"
      ;;
    codex)
      _harness_jq_edit "$file" "$_HARNESS_JQ_OURS"'
        def strip: map(select(([.hooks[]?.command] | map(ours) | any) | not));
        .hooks = (.hooks // {})
        | .hooks.PostToolUse = (((.hooks.PostToolUse // []) | strip)
                                + [{matcher: "*", hooks: [{type: "command", command: $r}]}])
        | .hooks.PreToolUse  = (((.hooks.PreToolUse  // []) | strip)
                                + [{matcher: "*", hooks: [{type: "command", command: $a}]}])
      ' --arg r "$reinject" --arg a "$allow"
      ;;
    copilot)
      # A file of our own: .github/hooks/ loads every *.json in it.
      mkdir -p "$(dirname "$file")"
      jq -n --arg r "$reinject" --arg a "$allow" '{
        version: 1,
        hooks: {
          postToolUse: [{type: "command", bash: $r, timeoutSec: 10}],
          preToolUse:  [{type: "command", bash: $a, timeoutSec: 10}]
        }
      }' >"$file"
      ;;
  esac
}

harness_hooks_remove() {
  local root="$1" h="$2" file
  file="$root/$(harness_hook_file "$h")"
  [[ -n "$file" && -f "$file" ]] || return 0
  case "$h" in
    cursor)
      _harness_jq_edit "$file" "$_HARNESS_JQ_OURS"'
        reduce ("postToolUse", "preToolUse") as $ev (.;
          if (.hooks[$ev] | type) == "array" then
            .hooks[$ev] = [.hooks[$ev][] | select(.command | ours | not)]
            | (if (.hooks[$ev] | length) == 0 then del(.hooks[$ev]) else . end)
          else . end)
        | (if (.hooks // {}) == {} then del(.hooks) else . end)
      '
      _harness_prune_json "$file" "$root"
      ;;
    codex)
      _harness_jq_edit "$file" "$_HARNESS_JQ_OURS"'
        reduce ("PostToolUse", "PreToolUse") as $ev (.;
          if (.hooks[$ev] | type) == "array" then
            .hooks[$ev] = (.hooks[$ev] | map(select(([.hooks[]?.command] | map(ours) | any) | not)))
            | (if (.hooks[$ev] | length) == 0 then del(.hooks[$ev]) else . end)
          else . end)
        | (if (.hooks // {}) == {} then del(.hooks) else . end)
      '
      _harness_prune_json "$file" "$root"
      ;;
    copilot)
      rm -f "$file"
      rmdir "$root/.github/hooks" "$root/.github" 2>/dev/null || true
      ;;
  esac
  return 0
}

harness_hooks_has() {
  local root="$1" h="$2" file
  file="$root/$(harness_hook_file "$h")"
  [[ -n "$file" && -f "$file" ]] || return 1
  grep -qF "$HARNESS_HOOK_SCRIPT" "$file"
}

# ─── Sync: selected in, unselected out ───────────────────────────────────────
#
# What the setup scripts call. Each installs for the selected harnesses and
# clears the others, so a re-run after `init.sh --harness …` follows the change.

# Mirror a skill dir (in the setup script's staging) for every harness.
harness_skill_sync() {
  local root="$1" src="$2" name h
  name="$(basename "$src")"
  [[ -d "$src" ]] || return 0
  for h in $(harness_selected); do
    harness_skill_install "$root" "$h" "$src"
  done
  for h in $(harness_unselected); do
    harness_skill_remove "$root" "$h" "$name" "$src"
  done
  for h in $(harness_selected); do
    echo "  skills/$name → $(harness_skill_where "$h" "$name") ($(harness_label "$h"))"
  done
}

# Remove a skill's mirrors from every harness (uninstall).
harness_skill_purge() {
  local root="$1" name="$2" src="${3:-}" h
  for h in $HARNESS_ALL; do
    harness_skill_remove "$root" "$h" "$name" "$src"
  done
}

harness_rule_sync() {
  local root="$1" src="$2" name h
  name="$(basename "$src" .md)"
  for h in $(harness_selected); do
    harness_rule_install "$root" "$h" "$src"
    echo "  rule $name → $(harness_rule_where "$h" "$name")"
  done
  for h in $(harness_unselected); do
    harness_rule_remove "$root" "$h" "$name"
  done
}

harness_rule_purge() {
  local root="$1" name="$2" h
  for h in $HARNESS_ALL; do
    HARNESS_PURGE=1 harness_rule_remove "$root" "$h" "$name"
  done
}

# Register a server for every selected harness, and drop it from the others.
harness_mcp_sync() {
  local root="$1" name="$2" spec="$3" h
  for h in $(harness_selected); do
    if harness_mcp_put "$root" "$h" "$name" "$spec"; then
      echo "  ✓ $(harness_mcp_file "$h") — $name ($(harness_label "$h"))"
    fi
  done
  for h in $(harness_unselected); do
    harness_mcp_remove "$root" "$h" "$name"
  done
  return 0
}

harness_mcp_purge() {
  local root="$1" name="$2" h
  for h in $HARNESS_ALL; do
    if harness_mcp_has "$root" "$h" "$name"; then
      harness_mcp_remove "$root" "$h" "$name"
      echo "  removed $name from $(harness_mcp_file "$h")"
    fi
  done
  return 0
}

# ─── Ignore entries ──────────────────────────────────────────────────────────

# .gitignore lines for what a harness's adapters generate under <root>. Only
# exact generated paths for folders the host may also own (.github/, .vscode/).
harness_gitignore_entries() {
  local root="$1" h="$2" rules_dir="${3:-}" f n
  case "$h" in
    claude)  printf '%s\n' '.claude/*' '!.claude/memory/' '.claude/' '.mcp.json' ;;
    cursor)  printf '%s\n' '.cursor/' ;;
    codex)
      printf '%s\n' '.codex/'
      # AGENTS.md is the host's file unless all of it is ours.
      _harness_agents_md_all_ours "$root" && echo 'AGENTS.md'
      ;;
    copilot)
      printf '%s\n' ".github/hooks/$HARNESS_MARK.json" '.vscode/mcp.json'
      if [[ -n "$rules_dir" ]]; then
        for f in "$rules_dir"/*.md; do
          [[ -f "$f" ]] || continue
          n="$(basename "$f" .md)"
          echo ".github/instructions/$n.instructions.md"
        done
      fi
      ;;
    antigravity) printf '%s\n' '.agent/' ;;
  esac
  return 0
}

# Is AGENTS.md entirely generated sections (so it can be ignored)?
_harness_agents_md_all_ours() {
  [[ -f "$1/AGENTS.md" ]] || return 1
  ! grep -v -e '^[[:space:]]*$' "$1/AGENTS.md" \
    | awk -v m="$HARNESS_MARK:rule" '
        index($0, "<!-- " m " ") == 1 { inb = 1; next }
        index($0, "<!-- /" m " ") == 1 { inb = 0; next }
        !inb { found = 1 } END { exit !found }'
}
