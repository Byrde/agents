#!/usr/bin/env bash
# Configure the GitHub tool: .agents/tools/github.md from template + project-local MCP.
#
# Run from the repository/project root you want to configure (current working directory).
# Writes:
#   - .cursor/mcp.json          — Cursor project MCP
#   - .mcp.json                 — Claude Code project MCP (root file; upstream does not use .claude/ for MCP)
#
# Does not modify $HOME. Does not invoke the cursor or claude CLIs; only merges JSON with jq.
#
# Usage: cd /path/to/project && /path/to/setup-github.sh
#
# Requires: gh, jq, python3 (template substitution only)
# Compatible with Bash 3.2 (macOS): no mapfile/readarray.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENTS_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TOOL_DIR="$AGENTS_ROOT/tools"
GITHUB_TEMPLATE="$TOOL_DIR/github.md.template"
GITHUB_OUT="$TOOL_DIR/github.md"

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
  echo "  Configure the GitHub agent tool for this project: interactive picker"
  echo "  (gh), then render .agents/tools/github.md and merge the GitHub MCP"
  echo "  server into project-local .cursor/mcp.json and .mcp.json."
  echo ""
  printf '  %-16s %s\n' "Project Root" "$project_root"
  printf '  %-16s %s\n' "Auth" "GitHub CLI (token via gh auth token)"
  echo "$bar"
  echo ""
}

list_gh_accounts() {
  gh auth status --json hosts | jq -r '
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

parse_account_row() {
  local row="$1"
  GH_HOST="${row%%$'\t'*}"
  local rest="${row#*$'\t'}"
  GH_LOGIN="${rest%% (active)}"
}

list_org_logins() {
  gh api user/orgs --paginate --jq '.[].login' 2>/dev/null | sort -f || true
}

list_repos_for_owner() {
  local owner="$1"
  gh repo list "$owner" -L 200 --json nameWithOwner | jq -r '.[].nameWithOwner'
}

list_projects_for_owner() {
  local owner="$1"
  gh project list --owner "$owner" -L 100 --closed --format json |
    jq -r '.projects[] | "\(.title)\t\(.number)\(if .closed then " (closed)" else "" end)"'
}

render_github_md() {
  local account="$1" repo="$2" project="$3"
  [[ -f "$GITHUB_TEMPLATE" ]] || die "missing template: $GITHUB_TEMPLATE"
  GITHUB_TEMPLATE="$GITHUB_TEMPLATE" GITHUB_OUT="$GITHUB_OUT" \
    RENDER_ACCOUNT="$account" RENDER_REPOSITORY="$repo" RENDER_PROJECT="$project" \
    python3 <<'PY'
from pathlib import Path
import os
src = Path(os.environ["GITHUB_TEMPLATE"])
dst = Path(os.environ["GITHUB_OUT"])
text = src.read_text()
out = (
    text.replace("{{ACCOUNT}}", os.environ["RENDER_ACCOUNT"])
    .replace("{{REPOSITORY}}", os.environ["RENDER_REPOSITORY"])
    .replace("{{PROJECT}}", os.environ["RENDER_PROJECT"])
)
dst.write_text(out)
print("Wrote", dst)
PY
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

main() {
  case "${1:-}" in
    -h | --help | help)
      echo "$PROG_NAME · Byrde Agents v$TOOL_VERSION"
      echo ""
      echo "Usage:"
      echo "  cd /your/project && $0"
      echo ""
      echo "Writes:"
      echo "  .agents/tools/github.md     — from github.md.template"
      echo "  .cursor/mcp.json           — Cursor project MCP"
      echo "  .mcp.json                  — Claude Code project MCP"
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
  picked_display="$(pick_from_menu "GitHub CLI accounts (from gh auth status):" "${display_options[@]}")"
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

  echo "Switching active GitHub CLI account to $GH_LOGIN …"
  gh auth switch -u "$GH_LOGIN" -h github.com

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

  local repos=()
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -n "$line" ]] && repos+=("$line")
  done < <(list_repos_for_owner "$repo_owner")
  [[ ${#repos[@]} -gt 0 ]] || die "no repositories returned for owner: $repo_owner"

  local repo_pick
  repo_pick="$(pick_from_menu "Repositories for $repo_owner:" "${repos[@]}")"

  local project_lines=()
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -n "$line" ]] && project_lines+=("$line")
  done < <(list_projects_for_owner "$repo_owner")
  local project_name=""
  if [[ ${#project_lines[@]} -eq 0 ]]; then
    read -r -p "No GitHub Projects found for '$repo_owner'. Enter project board title: " project_name || true
    [[ -n "$project_name" ]] || die "project title required"
  else
    local -a proj_labels=()
    local line
    for line in "${project_lines[@]}"; do
      local t="${line%%$'\t'*}"
      proj_labels+=("$t")
    done
    project_name="$(pick_from_menu "Project boards for $repo_owner:" "${proj_labels[@]}")"
  fi

  render_github_md "$repo_owner" "$repo_pick" "$project_name"

  local tok
  tok="$(gh auth token -h github.com)"

  echo ""
  read -r -p "Merge GitHub MCP into $cursor_mcp? [Y/n] " a_cursor
  if [[ "${a_cursor:-y}" =~ ^[Yy]|^$ ]]; then
    merge_cursor_mcp_github "$tok" "$cursor_mcp"
  fi

  echo ""
  read -r -p "Merge GitHub MCP into $claude_mcp (Claude Code project MCP)? [Y/n] " a_claude
  if [[ "${a_claude:-y}" =~ ^[Yy]|^$ ]]; then
    merge_claude_mcp_github "$tok" "$claude_mcp"
  fi

  echo ""
  echo "Done. Restoring previous active GitHub CLI account: ${prior_github_login:-unknown}"
}

main "$@"
