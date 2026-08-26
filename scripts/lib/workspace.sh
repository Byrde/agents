#!/usr/bin/env bash
# Byrde Agents — workspace repo map (shared lib).
#
# The workspace map is a small JSON file describing the repositories an agent
# context spans, so the always-on `workspace` rule can route a task to the right
# repo. It ALWAYS exists once configured — a single-repo folder gets a one-entry
# map, a multi-repo workspace gets one entry per repo. The mono/multi flavour is
# a DECLARED choice (`.mode`), recorded here and read back by resolve_layout.
#
# Schema (.workspace.agents.json, at the context root):
#   {
#     "mode": "mono" | "multi",
#     "contextRoot": ".",                 # where the agent opens (holds .agents)
#     "generated": "<iso8601>",
#     "repos": [
#       { "name": "...", "path": "<rel>", "remote": "...", "owner": "...",
#         "stack": ["scala","docker"], "purpose": "<human-editable>" }
#     ],
#     "githubAccount": "<gh login>"      # optional, human-authored
#   }
#
# Auto-detected fields (path/remote/owner/stack) are refreshed on regeneration;
# the human-authored `purpose` and `githubAccount` are preserved across refreshes.
#
# `githubAccount` pins which GitHub account this workspace's MCP token belongs
# to, for somebody who works across several client organisations. Absent means
# the machine-active `gh` account. Read by scripts/mcp/gh-mcp-headers.sh.
#
# Source AFTER lib/layout.sh (so AGENTS_ROOT / WORKSPACE_ROOT / SIBLING_REPOS are
# available). Requires jq. Compatible with Bash 3.2 (macOS).

# The map lives at the CONTEXT ROOT — the folder the agent opens in (the one that
# holds .agents) — as `.workspace.agents.json`, so the agent reads it at a stable
# top-level path. It is per-checkout state (which repos are cloned here),
# gitignored. Derived from AGENTS_ROOT's parent so it's stable regardless of cwd.
WORKSPACE_FILE="${WORKSPACE_FILE:-$(cd "$AGENTS_ROOT/.." && pwd)/.workspace.agents.json}"

# Echo the declared mode (mono|multi) from the map, or nothing. Overrides the
# weak stub in layout.sh so resolve_layout can honour the declared flavour.
workspace_declared_mode() {
  [[ -f "$WORKSPACE_FILE" ]] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  jq -r '.mode // empty' "$WORKSPACE_FILE" 2>/dev/null || true
}

# Detect the stack of a repo from marker files. Echoes space-separated tags.
workspace_detect_stack() {
  local p="$1" t=""
  [[ -f "$p/package.json" ]] && t="$t node"
  [[ -f "$p/tsconfig.json" ]] && t="$t typescript"
  { [[ -f "$p/build.sbt" ]] || ls "$p"/*.sbt >/dev/null 2>&1; } && t="$t scala"
  [[ -f "$p/go.mod" ]] && t="$t go"
  { [[ -f "$p/pom.xml" ]] || [[ -f "$p/build.gradle" ]] || [[ -f "$p/build.gradle.kts" ]]; } && t="$t jvm"
  { [[ -f "$p/pyproject.toml" ]] || [[ -f "$p/requirements.txt" ]] || [[ -f "$p/setup.py" ]]; } && t="$t python"
  [[ -f "$p/Cargo.toml" ]] && t="$t rust"
  [[ -f "$p/Gemfile" ]] && t="$t ruby"
  [[ -f "$p/Dockerfile" ]] && t="$t docker"
  # trim leading/trailing space
  t="${t#"${t%%[![:space:]]*}"}"
  t="${t%"${t##*[![:space:]]}"}"
  echo "$t"
}

# Parse owner from a git remote URL (handles scp-like and https forms).
# git@github.com:telus/foo.git → telus ;  https://github.com/telus/foo → telus
workspace_parse_owner() {
  local p="${1%.git}" rest
  rest="${p%/*}"
  echo "${rest##*[:/]}"
}

# Build one repo JSON object. $1=name $2=relpath(from contextRoot) $3=abspath
_workspace_repo_obj() {
  local name="$1" rel="$2" abs="$3" remote owner stack
  remote="$(git -C "$abs" remote get-url origin 2>/dev/null || echo "")"
  owner=""
  [[ -n "$remote" ]] && owner="$(workspace_parse_owner "$remote")"
  stack="$(workspace_detect_stack "$abs")"
  jq -n --arg name "$name" --arg path "$rel" --arg remote "$remote" \
        --arg owner "$owner" --arg stack "$stack" '
    { name: $name, path: $path, remote: $remote, owner: $owner,
      stack: ($stack | if . == "" then [] else split(" ") end),
      purpose: "" }'
}

# Generate/refresh the workspace map. $1 = mode (mono|multi). Requires
# WORKSPACE_ROOT (and, for multi, SIBLING_REPOS) from resolve_layout. Preserves
# human-edited `purpose` fields from any existing map (merged by repo name).
workspace_generate() {
  local mode="$1"
  command -v jq >/dev/null 2>&1 || { echo "error: jq required to write the workspace map" >&2; return 1; }

  local tmpdir n=0 r
  tmpdir="$(mktemp -d)"
  if [[ "$mode" == "mono" ]]; then
    _workspace_repo_obj "$(basename "$WORKSPACE_ROOT")" "." "$WORKSPACE_ROOT" >"$tmpdir/$n.json"
    n=$((n + 1))
  else
    for r in ${SIBLING_REPOS[@]+"${SIBLING_REPOS[@]}"}; do
      _workspace_repo_obj "$r" "$r" "$WORKSPACE_ROOT/$r" >"$tmpdir/$n.json"
      n=$((n + 1))
    done
  fi

  local new_repos
  if [[ "$n" -gt 0 ]]; then
    new_repos="$(jq -s '.' "$tmpdir"/*.json)"
  else
    new_repos="[]"
  fi
  rm -rf "$tmpdir"

  # Preserve purpose from the prior map (first non-empty match by name wins).
  local merged="$new_repos"
  if [[ -f "$WORKSPACE_FILE" ]]; then
    merged="$(jq -n --argjson new "$new_repos" --slurpfile old "$WORKSPACE_FILE" '
      (($old[0].repos) // []) as $o
      | $new | map(
          .name as $nm
          | .purpose = ([ $o[] | select(.name == $nm) | .purpose ]
                        | map(select(. != null and . != "")) | (.[0] // ""))
        )')"
  fi

  # Preserve the human-authored account pin. The writer below emits a fixed set
  # of top-level keys, so anything not carried over here is silently dropped —
  # and a pin that disappears on the next `init.sh` is worse than no pin, because
  # the workspace goes back to the machine-active account without saying so.
  local account=""
  if [[ -f "$WORKSPACE_FILE" ]]; then
    account="$(jq -r '.githubAccount // empty' "$WORKSPACE_FILE" 2>/dev/null || true)"
  fi

  local stamp
  stamp="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "")"
  jq -n --arg mode "$mode" --arg stamp "$stamp" --argjson repos "$merged" \
        --arg account "$account" '
    { mode: $mode, contextRoot: ".", generated: $stamp, repos: $repos }
    | if $account != "" then .githubAccount = $account else . end' \
    >"$WORKSPACE_FILE"
}

# Echo this workspace's pinned GitHub account, or nothing. The headers helper
# reads the map directly (it runs standalone, outside this library).
workspace_github_account() {
  [[ -f "$WORKSPACE_FILE" ]] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  jq -r '.githubAccount // empty' "$WORKSPACE_FILE" 2>/dev/null || true
}

# Print a compact human summary of the current map (for setup/doctor output).
workspace_summary() {
  [[ -f "$WORKSPACE_FILE" ]] || { echo "  (no workspace map)"; return 0; }
  command -v jq >/dev/null 2>&1 || { echo "  (jq unavailable)"; return 0; }
  jq -r '
    "  mode: \(.mode)   repos: \(.repos | length)",
    (.repos[] | "    - \(.name)  [\(.stack | join(","))]\(if .owner != "" then "  \(.owner)" else "" end)\(if .purpose != "" then "  — \(.purpose)" else "" end)")
  ' "$WORKSPACE_FILE" 2>/dev/null || echo "  (unreadable map)"
}

# True (0) if any repo in the map has a github.com remote — used by init.sh to
# decide whether to auto-register the account-wide GitHub MCP server.
workspace_has_github_remote() {
  [[ -f "$WORKSPACE_FILE" ]] || return 1
  command -v jq >/dev/null 2>&1 || return 1
  jq -e '[.repos[]?.remote // ""] | any(test("github\\.com"))' "$WORKSPACE_FILE" >/dev/null 2>&1
}

# Note: the map's .gitignore entry is managed by init.sh's single byrde-agents
# block (manage_editor_gitignore), alongside .claude/, .cursor/, and .mcp.json —
# not here. The always-on workspace rule likewise ships in .agents/rules/ and is
# installed/removed by init.sh's copy_rules / remove_rules.
