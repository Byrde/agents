#!/usr/bin/env bash
# Configure the github-projects tool skill: pin a GitHub project board (work
# items, milestones, board state) and ensure the GitHub MCP server is registered.
#
# This is the one GitHub capability that needs configuration — a project board
# (owner + project number) can't be auto-detected. Source-control (branches,
# PRs, review) is NOT configured here: it's an always-on rule installed by
# init.sh, and the account-wide GitHub MCP it uses is registered by init.sh too.
#
# Run from the folder your agent opens in (the one that contains .agents):
#   cd /your/workspace && /path/to/setup-github-project.sh
#
# Writes:
#   - skills/github-projects/SKILL.md (+ mirrored into .claude/ and .cursor/)
#   - .mcp.json / .cursor/mcp.json — ensures the GitHub MCP server is present
#
# Requires: gh (authenticated), jq, python3. Bash 3.2 (macOS) compatible.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENTS_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib/layout.sh
. "$SCRIPT_DIR/lib/layout.sh"
resolve_layout
# shellcheck source=lib/manifest.sh
. "$SCRIPT_DIR/lib/manifest.sh"
# shellcheck source=lib/mcp.sh
. "$SCRIPT_DIR/lib/mcp.sh"
TOOL_DIR="$AGENTS_ROOT/tools"
PROJECTS_TEMPLATE="$TOOL_DIR/github-projects.md.template"
PROJECTS_OUT="$SKILLS_DIR/github-projects/SKILL.md"

TOOL_VERSION="0.1.0"
PROG_NAME="$(basename "${BASH_SOURCE[0]}")"

die() {
  echo "error: $*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing required command: $1 (install or add to PATH)"
}

prior_github_login=""
save_prior_gh_login() {
  prior_github_login="$(
    gh auth status --json hosts 2>/dev/null | jq -r '
      (.hosts["github.com"] // [])
      | map(select(.active and .state == "success"))
      | if length == 0 then "" else .[0].login end
    '
  )"
}

restore_gh_login() {
  if [[ -n "${prior_github_login:-}" ]]; then
    gh auth switch -u "$prior_github_login" -h github.com >/dev/null 2>&1 || true
  fi
}

trap restore_gh_login EXIT

print_intro() {
  local bar
  bar="$(printf '%*s' 68 '' | tr ' ' '=')"
  echo "$bar"
  echo "  $PROG_NAME · Byrde Agents  v$TOOL_VERSION"
  echo ""
  echo "  Pin a GitHub project board and install the github-projects skill."
  echo "  (Source-control is an always-on rule + MCP set up by init.sh.)"
  echo ""
  printf '  %-16s %s\n' "Context Root" "$WORKSPACE_ROOT"
  printf '  %-16s %s\n' "Layout" "$(layout_describe)"
  echo "$bar"
  echo ""
}

list_gh_accounts() {
  gh auth status --json hosts 2>/dev/null | jq -r '
    .hosts | to_entries[] | .key as $host | .value[]
    | select(.state == "success")
    | "\($host)\t\(.login)\(if .active then " (active)" else "" end)"
  ' | sort -t $'\t' -k1,1 -k2,2f
}

pick_from_menu() {
  local title="$1"; shift
  local -a choices=("$@")
  [[ ${#choices[@]} -gt 0 ]] || die "no options for: $title"
  echo "" >&2; echo "$title" >&2
  local i=1 c
  for c in "${choices[@]}"; do echo "  $i) $c" >&2; ((i++)) || true; done
  local sel
  while true; do
    read -r -p "Enter number (1-${#choices[@]}): " sel || die "stdin closed"
    if [[ "$sel" =~ ^[0-9]+$ ]] && ((sel >= 1 && sel <= ${#choices[@]})); then
      echo "${choices[$((sel - 1))]}"; return 0
    fi
    echo "Invalid choice." >&2
  done
}

prompt_repo() {
  local owner="$1" sel
  while true; do
    echo "" >&2
    read -r -p "Repository the board mainly tracks (under $owner): " sel || die "stdin closed"
    [[ -n "$sel" ]] || { echo "Repository name cannot be empty." >&2; continue; }
    if gh repo view "$owner/$sel" >/dev/null 2>&1; then echo "$owner/$sel"; return 0; fi
    echo "Repository not found: $owner/$sel" >&2
  done
}

gh_has_project_scope() {
  local scopes
  scopes="$(gh auth status -h github.com 2>&1 | sed -n 's/.*Token scopes: //p')"
  [[ "$scopes" == *"'read:project'"* || "$scopes" == *"'project'"* ]]
}

ensure_project_scope() {
  gh_has_project_scope && return 0
  local scopes
  scopes="$(gh auth status -h github.com 2>&1 | sed -n 's/.*Token scopes: //p')"
  echo "" >&2
  echo "github-projects needs the 'read:project' gh scope, which this token lacks." >&2
  echo "  Current scopes: ${scopes:-unknown}" >&2
  echo "" >&2
  local ans
  read -r -p "Add it now via 'gh auth refresh -h github.com -s read:project'? [Y/n] " ans
  if [[ "${ans:-y}" =~ ^[Yy]|^$ ]]; then
    gh auth refresh -h github.com -s read:project && gh_has_project_scope && { echo "  ✓ read:project added." >&2; return 0; }
    echo "warning: read:project still not present after refresh." >&2
  fi
  return 1
}

prompt_project_id() {
  local owner="$1" sel err
  while true; do
    echo "" >&2
    read -r -p "Project board ID (numeric): " sel || die "stdin closed"
    [[ "$sel" =~ ^[0-9]+$ ]] || { echo "Must be a number." >&2; continue; }
    if err="$(gh project view "$sel" --owner "$owner" 2>&1 >/dev/null)"; then echo "$sel"; return 0; fi
    echo "Project lookup failed for ID $sel under $owner:" >&2
    echo "  $err" >&2
  done
}

parse_account_row() {
  local row="$1"
  GH_HOST="${row%%$'\t'*}"
  local rest="${row#*$'\t'}"
  GH_LOGIN="${rest%% (active)}"
}

list_org_logins() {
  gh api user/orgs --paginate --jq '.[].login' 2>/dev/null | sort -f || true
}

render_skill() {
  local template="$1" out="$2" account="$3" repo="$4" project_id="$5"
  [[ -f "$template" ]] || die "missing template: $template"
  mkdir -p "$(dirname "$out")"
  RENDER_TEMPLATE="$template" RENDER_OUT="$out" \
    RENDER_ACCOUNT="$account" RENDER_REPOSITORY="$repo" RENDER_PROJECT_ID="$project_id" \
    python3 <<'PY'
from pathlib import Path
import os
src = Path(os.environ["RENDER_TEMPLATE"]); dst = Path(os.environ["RENDER_OUT"])
out = (src.read_text()
       .replace("{{ACCOUNT}}", os.environ["RENDER_ACCOUNT"])
       .replace("{{REPOSITORY}}", os.environ["RENDER_REPOSITORY"])
       .replace("{{PROJECT_ID}}", os.environ["RENDER_PROJECT_ID"]))
dst.write_text(out); print("Wrote", dst)
PY
}

sync_skill_to_editors() {
  local skill="$1" src="$SKILLS_DIR/$skill"
  [[ -d "$src" ]] || return 0
  local dest
  for dest in "$WORKSPACE_ROOT/.claude/skills" "$WORKSPACE_ROOT/.cursor/skills"; do
    mkdir -p "$dest"; rm -rf "${dest:?}/$skill"; cp -R "$src" "$dest/$skill"
    echo "  skills/$skill → ${dest#"$WORKSPACE_ROOT"/}/$skill"
  done
}

# ─── Uninstall ────────────────────────────────────────────────────────────────

uninstall() {
  require_cmd jq
  local bar
  bar="$(printf '%*s' 68 '' | tr ' ' '=')"
  echo "$bar"
  echo "  $PROG_NAME · Uninstall  v$TOOL_VERSION"
  echo ""
  echo "  Removes the github-projects skill. Leaves the GitHub MCP server in"
  echo "  place — it's shared with the always-on source-control rule and is"
  echo "  managed by init.sh (run 'init.sh uninstall' to remove it)."
  echo "$bar"
  echo ""
  rm -rf "$SKILLS_DIR/github-projects"
  echo "  removed skills/github-projects"
  local dest
  for dest in "$WORKSPACE_ROOT/.claude/skills/github-projects" "$WORKSPACE_ROOT/.cursor/skills/github-projects"; do
    rm -rf "$dest"; echo "  removed ${dest#"$WORKSPACE_ROOT"/}"
  done
  manifest_remove "github-projects"
  echo ""
  echo "Done. Restart your editor so it drops the github-projects skill."
}

# ─── Main ────────────────────────────────────────────────────────────────────

main() {
  case "${1:-}" in
    -h | --help | help)
      echo "$PROG_NAME · Byrde Agents v$TOOL_VERSION"
      echo ""
      echo "Pins a GitHub project board and installs the github-projects skill."
      echo "Source-control (branches/PRs/review) is an always-on rule from init.sh."
      echo ""
      echo "Usage:"
      echo "  cd /your/workspace && $0              # configure the project board"
      echo "  cd /your/workspace && $0 uninstall    # remove the github-projects skill"
      exit 0
      ;;
    uninstall | remove)
      uninstall
      exit 0
      ;;
  esac

  require_cmd gh
  require_cmd jq
  require_cmd python3
  gh auth status -h github.com >/dev/null 2>&1 || die "not logged in to github.com — run: gh auth login"

  save_prior_gh_login
  print_intro

  # ── Account picker ────────────────────────────────────────────────────────
  local account_rows=() line
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -n "$line" ]] && account_rows+=("$line")
  done < <(list_gh_accounts)
  [[ ${#account_rows[@]} -gt 0 ]] || die "no authenticated GitHub accounts in gh auth status"

  local display_options=() r
  for r in "${account_rows[@]}"; do parse_account_row "$r"; display_options+=("$GH_LOGIN @ $GH_HOST"); done

  local picked_display
  if [[ ${#display_options[@]} -eq 1 ]]; then
    picked_display="${display_options[0]}"
    echo "Using GitHub account: $picked_display"
  else
    picked_display="$(pick_from_menu "GitHub CLI accounts (from gh auth status):" "${display_options[@]}")"
  fi
  local idx=0 found=-1
  for r in "${display_options[@]}"; do
    [[ "$r" == "$picked_display" ]] && { found=$idx; break; }; ((idx++)) || true
  done
  [[ "$found" -ge 0 ]] || die "internal menu error"
  parse_account_row "${account_rows[$found]}"
  [[ "$GH_HOST" == "github.com" ]] || die "only github.com is supported (selected: $GH_HOST)"
  gh auth switch -u "$GH_LOGIN" -h github.com >/dev/null 2>&1

  ensure_project_scope || die "github-projects needs the read:project scope. Add it with: gh auth refresh -h github.com -s read:project"

  # ── Owner ───────────────────────────────────────────────────────────────────
  local repo_owner="" orgs=()
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -n "$line" ]] && orgs+=("$line")
  done < <(list_org_logins)
  if [[ ${#orgs[@]} -eq 0 ]]; then
    repo_owner="$GH_LOGIN"
    echo "Using personal account for: $repo_owner"
  else
    local -a owner_choices=("Personal ($GH_LOGIN)") o
    for o in "${orgs[@]}"; do owner_choices+=("Organization: $o"); done
    local scope_choice
    scope_choice="$(pick_from_menu "Project board owner:" "${owner_choices[@]}")"
    if [[ "$scope_choice" == "Personal ($GH_LOGIN)" ]]; then repo_owner="$GH_LOGIN"; else repo_owner="${scope_choice#Organization: }"; fi
  fi

  # ── Repo the board mainly tracks + board ID ─────────────────────────────────
  local repo_pick repo_name project_id
  repo_pick="$(prompt_repo "$repo_owner")"
  repo_name="${repo_pick#"${repo_owner}"/}"
  project_id="$(prompt_project_id "$repo_owner")"

  # ── Render skill ────────────────────────────────────────────────────────────
  echo ""
  echo "── Installing github-projects skill ──"
  ignore_skills_home
  render_skill "$PROJECTS_TEMPLATE" "$PROJECTS_OUT" "$repo_owner" "$repo_name" "$project_id"
  sync_skill_to_editors "github-projects"
  manifest_add "github-projects"

  # ── Ensure the GitHub MCP is registered (init normally owns this) ──────────
  echo ""
  echo "── Ensuring GitHub MCP ──"
  mcp_merge_github "$WORKSPACE_ROOT"
  echo "    auth: Claude Code pulls the token from 'gh auth token' live (no setup);"
  echo "          Cursor users export GITHUB_PERSONAL_ACCESS_TOKEN."

  echo ""
  echo "Done. Board $repo_owner #$project_id (tracks $repo_pick)."
  echo "  Verify with: .agents/scripts/doctor.sh"
  [[ -n "${prior_github_login:-}" ]] && echo "  Restoring previous active GitHub CLI account: $prior_github_login"
}

main "$@"
