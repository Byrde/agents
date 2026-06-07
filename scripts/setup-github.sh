#!/usr/bin/env bash
# Configure the GitHub tool skills: render per-capability templates into
# .agents/skills/ and merge the GitHub MCP server into project-local configs.
#
# Two opt-in capabilities:
#   - github-source-control  → branches, pull requests, code review
#   - github-projects        → work items, milestones, project board
# Pick either, both, or neither.
#
# Run from the repository/project root you want to configure (current working
# directory).
#
# Writes (per opted-in capability):
#   - .agents/skills/github-source-control/SKILL.md
#   - .agents/skills/github-projects/SKILL.md
#   - .cursor/mcp.json   — Cursor project MCP
#   - .mcp.json          — Claude Code project MCP
#
# Does not modify $HOME. Does not invoke the cursor or claude CLIs; only
# merges JSON with jq.
#
# Usage: cd /path/to/project && /path/to/setup-github.sh
#
# Requires: gh, jq, python3 (template substitution only)
# Compatible with Bash 3.2 (macOS): no mapfile/readarray.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENTS_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TOOL_DIR="$AGENTS_ROOT/tools"
SKILLS_DIR="$AGENTS_ROOT/skills"
SOURCE_CONTROL_TEMPLATE="$TOOL_DIR/github-source-control.md.template"
SOURCE_CONTROL_OUT="$SKILLS_DIR/github-source-control/SKILL.md"
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
  local project_root="$1"
  local bar
  bar="$(printf '%*s' 68 '' | tr ' ' '=')"
  echo "$bar"
  echo "  $PROG_NAME · Byrde Agents  v$TOOL_VERSION"
  echo ""
  echo "  Install GitHub tool skills into .agents/skills/ and wire up the"
  echo "  GitHub MCP server in your editor's project config."
  echo ""
  echo "  Two opt-in capabilities — install either, both, or neither:"
  echo "    • github-source-control  branches, PRs, code review"
  echo "    • github-projects        work items, milestones, project board"
  echo ""
  printf '  %-16s %s\n' "Project Root" "$project_root"
  printf '  %-16s %s\n' "Auth" "GitHub CLI (token via gh auth token)"
  echo "$bar"
  echo ""
}

print_summary() {
  local bar
  bar="$(printf '%*s' 68 '' | tr ' ' '=')"
  echo ""
  echo "$bar"
  echo "  $PROG_NAME · Summary"
  echo "$bar"
  echo ""
  printf '  %-16s %s\n' "Repository" "$repo_pick"
  if [[ "$install_pr" == "y" ]]; then
    printf '  %-16s %s\n' "Project board" "$project_id"
  fi
  echo ""
  echo "  Skills:"
  if [[ "$install_sc" == "y" ]]; then
    echo "    ✓ github-source-control  → $SOURCE_CONTROL_OUT"
  else
    echo "    - github-source-control  (declined)"
  fi
  if [[ "$install_pr" == "y" ]]; then
    echo "    ✓ github-projects        → $PROJECTS_OUT"
  else
    echo "    - github-projects        (declined)"
  fi
  echo ""
  echo "  MCP server:"
  printf '    %-13s %s\n' "Cursor:"      "${cursor_status:-skipped}"
  printf '    %-13s %s\n' "Claude Code:" "${claude_status:-skipped}"
  echo ""
  echo "  Verify with: .agents/scripts/doctor.sh"
  echo "  Undo with:   .agents/scripts/setup-github.sh uninstall"
  echo "$bar"
}

list_gh_accounts() {
  gh auth status --json hosts 2>/dev/null | jq -r '
    .hosts
    | to_entries[]
    | .key as $host
    | .value[]
    | select(.state == "success")
    | "\($host)\t\(.login)\(if .active then " (active)" else "" end)"
  ' | sort -t $'\t' -k1,1 -k2,2f
}

pick_from_menu() {
  local title="$1"
  shift
  local -a choices=("$@")
  if [[ ${#choices[@]} -eq 0 ]]; then
    die "no options for: $title"
  fi
  echo "" >&2
  echo "$title" >&2
  local i=1
  local c
  for c in "${choices[@]}"; do
    echo "  $i) $c" >&2
    ((i++)) || true
  done
  local sel
  while true; do
    read -r -p "Enter number (1-${#choices[@]}): " sel || die "stdin closed"
    if [[ "$sel" =~ ^[0-9]+$ ]] && ((sel >= 1 && sel <= ${#choices[@]})); then
      echo "${choices[$((sel - 1))]}"
      return 0
    fi
    echo "Invalid choice." >&2
  done
}

prompt_repo() {
  local owner="$1"
  local sel
  while true; do
    echo "" >&2
    read -r -p "Repository name (under $owner): " sel || die "stdin closed"
    [[ -n "$sel" ]] || { echo "Repository name cannot be empty." >&2; continue; }
    if gh repo view "$owner/$sel" >/dev/null 2>&1; then
      echo "$owner/$sel"
      return 0
    else
      echo "Repository not found: $owner/$sel" >&2
    fi
  done
}

gh_has_project_scope() {
  local scopes
  scopes="$(gh auth status -h github.com 2>&1 | sed -n 's/.*Token scopes: //p')"
  [[ "$scopes" == *"'read:project'"* || "$scopes" == *"'project'"* ]]
}

# Ensures the active token carries read:project (needed by github-projects).
# If absent, offers to add it via `gh auth refresh` in place — no re-run needed.
# Returns 0 if the scope is present (or successfully added), 1 if not (caller
# can then drop github-projects and continue with whatever else was selected).
ensure_project_scope() {
  if gh_has_project_scope; then
    return 0
  fi
  local scopes
  scopes="$(gh auth status -h github.com 2>&1 | sed -n 's/.*Token scopes: //p')"
  echo "" >&2
  echo "github-projects needs the 'read:project' gh scope, which this token lacks." >&2
  echo "  Current scopes: ${scopes:-unknown}" >&2
  echo "" >&2
  local ans
  read -r -p "Add it now via 'gh auth refresh -h github.com -s read:project'? [Y/n] " ans
  if [[ "${ans:-y}" =~ ^[Yy]|^$ ]]; then
    if gh auth refresh -h github.com -s read:project && gh_has_project_scope; then
      echo "  ✓ read:project scope added." >&2
      return 0
    fi
    echo "warning: read:project still not present after refresh." >&2
  fi
  return 1
}

prompt_project_id() {
  local owner="$1"
  local sel err
  while true; do
    echo "" >&2
    read -r -p "Project ID (numeric): " sel || die "stdin closed"
    [[ -n "$sel" ]] || { echo "Project ID cannot be empty." >&2; continue; }
    [[ "$sel" =~ ^[0-9]+$ ]] || { echo "Must be a number." >&2; continue; }
    if err="$(gh project view "$sel" --owner "$owner" 2>&1 >/dev/null)"; then
      echo "$sel"
      return 0
    else
      echo "Project lookup failed for ID $sel under $owner:" >&2
      echo "  $err" >&2
    fi
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
src = Path(os.environ["RENDER_TEMPLATE"])
dst = Path(os.environ["RENDER_OUT"])
text = src.read_text()
out = (
    text.replace("{{ACCOUNT}}", os.environ["RENDER_ACCOUNT"])
    .replace("{{REPOSITORY}}", os.environ["RENDER_REPOSITORY"])
    .replace("{{PROJECT_ID}}", os.environ["RENDER_PROJECT_ID"])
)
dst.write_text(out)
print("Wrote", dst)
PY
}

# Mirror a skill from .agents/skills/ into the editor-local skill dirs, the
# same way init.sh seeds them. Without this, Claude Code (.claude/skills/) and
# Cursor (.cursor/skills/) never see skills that setup-github installs.
# Idempotent and tolerant of either the editor dir or the skill subdir already
# existing (mkdir -p the dest, then replace the skill subdir wholesale).
sync_skill_to_editors() {
  local project_root="$1" skill="$2"
  local src="$SKILLS_DIR/$skill"
  [[ -d "$src" ]] || return 0
  local dest
  for dest in "$project_root/.claude/skills" "$project_root/.cursor/skills"; do
    mkdir -p "$dest"
    rm -rf "${dest:?}/$skill"
    cp -R "$src" "$dest/$skill"
    echo "  skills/$skill → ${dest#$project_root/}/$skill"
  done
}

merge_json_mcp_github() {
  local target_file="$1"
  local token="$2"
  local tmp
  tmp="$(mktemp)"
  if [[ -f "$target_file" ]]; then
    jq --arg tok "$token" '
      .mcpServers = (.mcpServers // {}) |
      .mcpServers.github = {
        type: "http",
        url: "https://api.githubcopilot.com/mcp/",
        headers: { Authorization: ("Bearer " + $tok) }
      }
    ' "$target_file" >"$tmp" || die "jq failed on $target_file (invalid JSON?)"
  else
    mkdir -p "$(dirname "$target_file")"
    jq -n --arg tok "$token" '{
      mcpServers: {
        github: {
          type: "http",
          url: "https://api.githubcopilot.com/mcp/",
          headers: { Authorization: ("Bearer " + $tok) }
        }
      }
    }' >"$tmp"
  fi
  mv "$tmp" "$target_file"
  echo "Updated $target_file"
}

merge_cursor_mcp_github() {
  local token="$1"
  local path="$2"
  local tmp
  tmp="$(mktemp)"
  mkdir -p "$(dirname "$path")"
  if [[ -f "$path" ]]; then
    jq --arg tok "$token" '
      .mcpServers = (.mcpServers // {}) |
      .mcpServers.github = {
        url: "https://api.githubcopilot.com/mcp/",
        headers: { Authorization: ("Bearer " + $tok) }
      }
    ' "$path" >"$tmp" || die "jq failed on $path (invalid JSON?)"
  else
    jq -n --arg tok "$token" '{
      mcpServers: {
        github: {
          url: "https://api.githubcopilot.com/mcp/",
          headers: { Authorization: ("Bearer " + $tok) }
        }
      }
    }' >"$tmp"
  fi
  mv "$tmp" "$path"
  echo "Updated $path (restart Cursor to reload MCP)"
}

merge_claude_mcp_github() {
  local token="$1"
  local path="$2"
  merge_json_mcp_github "$path" "$token"
  echo "Restart Claude Code if it is running so MCP picks up changes to $path"
}

# ─── Uninstall ────────────────────────────────────────────────────────────────

# Remove a skill from .agents/skills/ and its editor mirrors. Reverses
# render_skill + sync_skill_to_editors.
remove_skill() {
  local project_root="$1" skill="$2"
  rm -rf "$SKILLS_DIR/$skill"
  echo "  removed skills/$skill"
  local dest
  for dest in "$project_root/.claude/skills/$skill" "$project_root/.cursor/skills/$skill"; do
    rm -rf "$dest"
    echo "  removed ${dest#$project_root/}"
  done
}

# Strip the github MCP server from a JSON config. Reverses the merge_*_github
# helpers (both write .mcpServers.github).
remove_mcp_github() {
  local path="$1"
  [[ -f "$path" ]] || return 0
  jq -e '.mcpServers.github' "$path" >/dev/null 2>&1 || return 0
  local tmp
  tmp="$(mktemp)"
  if jq 'del(.mcpServers.github)' "$path" >"$tmp" 2>/dev/null; then
    mv "$tmp" "$path"
    echo "  removed mcpServers.github from $path"
  else
    rm -f "$tmp"
    echo "  ⚠ jq failed on $path — left unchanged"
  fi
}

uninstall() {
  require_cmd jq

  local project_root
  project_root="$(pwd -P)"
  local cursor_mcp="$project_root/.cursor/mcp.json"
  local claude_mcp="$project_root/.mcp.json"

  local bar
  bar="$(printf '%*s' 68 '' | tr ' ' '=')"
  echo "$bar"
  echo "  $PROG_NAME · Uninstall  v$TOOL_VERSION"
  echo ""
  echo "  Removes the GitHub tool skills and the GitHub MCP server from your"
  echo "  editor configs. Does not touch your gh CLI auth."
  echo ""
  printf '  %-16s %s\n' "Project Root" "$project_root"
  echo "$bar"
  echo ""

  echo "── Removing skills ──"
  remove_skill "$project_root" "github-source-control"
  remove_skill "$project_root" "github-projects"
  echo ""

  echo "── Removing MCP registration ──"
  remove_mcp_github "$cursor_mcp"
  remove_mcp_github "$claude_mcp"
  echo ""

  echo "$bar"
  echo "  Done. GitHub skills and MCP server removed."
  echo "  Restart your editor so it drops the (now-removed) MCP server."
  echo "$bar"
}

main() {
  case "${1:-}" in
    -h | --help | help)
      echo "$PROG_NAME · Byrde Agents v$TOOL_VERSION"
      echo ""
      echo "Installs GitHub tool skills into .agents/skills/ and merges the"
      echo "GitHub MCP server into your editor's project-local config."
      echo ""
      echo "Usage:"
      echo "  cd /your/project && $0              # install"
      echo "  cd /your/project && $0 uninstall    # remove skills + GitHub MCP"
      echo ""
      echo "Opt-in capabilities (pick either, both, or neither):"
      echo "  github-source-control  branches, PRs, code review"
      echo "  github-projects        work items, milestones, project board"
      echo "                         (requires read:project gh scope)"
      echo ""
      echo "Writes (per opted-in capability):"
      echo "  .agents/skills/github-source-control/SKILL.md"
      echo "  .agents/skills/github-projects/SKILL.md"
      echo "  .cursor/mcp.json   — Cursor project MCP"
      echo "  .mcp.json          — Claude Code project MCP"
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

  local project_root
  project_root="$(pwd -P)"
  local cursor_mcp="$project_root/.cursor/mcp.json"
  local claude_mcp="$project_root/.mcp.json"

  save_prior_gh_login

  print_intro "$project_root"

  # ── Capability selection ─────────────────────────────────────────────────
  local install_sc="n" install_pr="n"
  echo "Which GitHub capabilities should be installed as skills?"
  echo ""
  read -r -p "Install github-source-control (branches, PRs, code review)? [Y/n] " a_sc
  [[ "${a_sc:-y}" =~ ^[Yy]|^$ ]] && install_sc="y"
  read -r -p "Install github-projects (issues, milestones, project board)? [Y/n] " a_pr
  [[ "${a_pr:-y}" =~ ^[Yy]|^$ ]] && install_pr="y"

  if [[ "$install_sc" != "y" && "$install_pr" != "y" ]]; then
    echo ""
    echo "Nothing selected — exiting without changes."
    exit 0
  fi

  # ── Account picker ───────────────────────────────────────────────────────
  local account_rows=()
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -n "$line" ]] && account_rows+=("$line")
  done < <(list_gh_accounts)
  [[ ${#account_rows[@]} -gt 0 ]] || die "no authenticated GitHub accounts in gh auth status"

  local display_options=()
  local r
  for r in "${account_rows[@]}"; do
    parse_account_row "$r"
    display_options+=("$GH_LOGIN @ $GH_HOST")
  done

  local picked_display
  if [[ ${#display_options[@]} -eq 1 ]]; then
    picked_display="${display_options[0]}"
    echo ""
    echo "Using GitHub account: $picked_display"
  else
    picked_display="$(pick_from_menu "GitHub CLI accounts (from gh auth status):" "${display_options[@]}")"
  fi
  local idx=0 found=-1
  for r in "${display_options[@]}"; do
    if [[ "$r" == "$picked_display" ]]; then
      found=$idx
      break
    fi
    ((idx++)) || true
  done
  [[ "$found" -ge 0 ]] || die "internal menu error"
  parse_account_row "${account_rows[$found]}"

  [[ "$GH_HOST" == "github.com" ]] || die "only github.com is supported (selected: $GH_HOST)"
  gh auth switch -u "$GH_LOGIN" -h github.com >/dev/null 2>&1

  # Project scope is only needed for github-projects. If it's missing and the
  # user declines to add it, drop github-projects rather than aborting the run.
  if [[ "$install_pr" == "y" ]] && ! ensure_project_scope; then
    echo ""
    echo "Skipping github-projects — no read:project scope."
    echo "  Add it later with: gh auth refresh -h github.com -s read:project"
    install_pr="n"
    if [[ "$install_sc" != "y" ]]; then
      die "nothing left to install (github-source-control was not selected)."
    fi
  fi

  # ── Owner + repo (needed by both capabilities) ───────────────────────────
  local repo_owner=""
  local orgs=()
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -n "$line" ]] && orgs+=("$line")
  done < <(list_org_logins)
  if [[ ${#orgs[@]} -eq 0 ]]; then
    repo_owner="$GH_LOGIN"
    echo "Using personal repositories for: $repo_owner"
  else
    local -a owner_choices=("Personal ($GH_LOGIN)")
    local o
    for o in "${orgs[@]}"; do
      owner_choices+=("Organization: $o")
    done
    local scope_choice
    scope_choice="$(pick_from_menu "Repository owner:" "${owner_choices[@]}")"
    if [[ "$scope_choice" == "Personal ($GH_LOGIN)" ]]; then
      repo_owner="$GH_LOGIN"
    else
      repo_owner="${scope_choice#Organization: }"
    fi
  fi

  local repo_pick
  repo_pick="$(prompt_repo "$repo_owner")"
  local repo_name="${repo_pick#${repo_owner}/}"

  # ── Project ID (only for github-projects) ────────────────────────────────
  local project_id=""
  if [[ "$install_pr" == "y" ]]; then
    project_id="$(prompt_project_id "$repo_owner")"
  fi

  # ── Render skills ────────────────────────────────────────────────────────
  if [[ "$install_sc" == "y" ]]; then
    render_skill "$SOURCE_CONTROL_TEMPLATE" "$SOURCE_CONTROL_OUT" \
      "$repo_owner" "$repo_name" "${project_id:-N/A}"
    # .agents/skills/ is the source of truth; mirror into the editor skill dirs
    # so Claude Code and Cursor pick it up without re-running init.sh.
    sync_skill_to_editors "$project_root" "github-source-control"
  fi
  if [[ "$install_pr" == "y" ]]; then
    render_skill "$PROJECTS_TEMPLATE" "$PROJECTS_OUT" \
      "$repo_owner" "$repo_name" "$project_id"
    sync_skill_to_editors "$project_root" "github-projects"
  fi

  # ── MCP merge ────────────────────────────────────────────────────────────
  local tok
  tok="$(gh auth token -h github.com 2>/dev/null)"

  cursor_status="skipped"
  claude_status="skipped"

  echo ""
  read -r -p "Merge GitHub MCP into $cursor_mcp? [Y/n] " a_cursor
  if [[ "${a_cursor:-y}" =~ ^[Yy]|^$ ]]; then
    merge_cursor_mcp_github "$tok" "$cursor_mcp"
    cursor_status="merged → $cursor_mcp"
  fi

  echo ""
  read -r -p "Merge GitHub MCP into $claude_mcp (Claude Code project MCP)? [Y/n] " a_claude
  if [[ "${a_claude:-y}" =~ ^[Yy]|^$ ]]; then
    merge_claude_mcp_github "$tok" "$claude_mcp"
    claude_status="merged → $claude_mcp"
  fi

  print_summary

  if [[ -n "${prior_github_login:-}" ]]; then
    echo ""
    echo "Restoring previous active GitHub CLI account: $prior_github_login"
  fi
}

main "$@"
