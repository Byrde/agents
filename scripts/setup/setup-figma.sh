#!/usr/bin/env bash
# Configure the Figma tool skill: render the template into .agents/skills/ and
# merge the Figma MCP server into project-local configs.
#
# One skill, one file: `figma` owns components, tokens, and the design work —
# all in a single Figma file. It overlays on figma-use (Figma's official
# plugin-API skill), vendored from upstream on every run.
#
# Run from the repository/project root you want to configure (current working
# directory).
#
# Writes:
#   - .agents/skills/figma/SKILL.md
#   - .agents/skills/figma-use/       — vendored from upstream
#   - .cursor/mcp.json   — Cursor project MCP (Figma server merged in)
#   - .mcp.json          — Claude Code project MCP (Figma server merged in)
#
# Does not modify $HOME. Does not invoke the cursor or claude CLIs; only
# merges JSON with jq.
#
# Usage: cd /path/to/project && /path/to/setup-figma.sh
#
# Requires: jq, python3, curl
# Compatible with Bash 3.2 (macOS): no mapfile/readarray.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENTS_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# Resolve mono- vs multi-repo layout (sets SKILLS_DIR + MANIFEST_FILE) BEFORE
# sourcing the manifest helper, which reads MANIFEST_FILE.
# shellcheck source=lib/layout.sh
. "$SCRIPT_DIR/../lib/layout.sh"
resolve_layout
# shellcheck source=lib/manifest.sh
. "$SCRIPT_DIR/../lib/manifest.sh"
TOOL_DIR="$AGENTS_ROOT/tools"  # templates: always the shared checkout
# SKILLS_DIR is set by resolve_layout (per-project staging home).
FIGMA_TEMPLATE="$TOOL_DIR/figma.md.template"
FIGMA_OUT="$SKILLS_DIR/figma/SKILL.md"

# Skill names retired when figma-design-system + figma-design-file merged into
# `figma`. Kept here so uninstall (and a re-run) cleans up older installs.
LEGACY_SKILLS="figma-design-system figma-design-file"

# Upstream figma-use skill — vendored from Figma's official MCP guide.
# Our skill overlays on top of this; it owns the plugin-API mechanics.
FIGMA_USE_REPO="https://github.com/figma/mcp-server-guide.git"
FIGMA_USE_SUBPATH="skills/figma-use"
FIGMA_USE_OUT="$SKILLS_DIR/figma-use"

FIGMA_API="https://api.figma.com"
FIGMA_MCP_URL="https://mcp.figma.com/mcp"

TOOL_VERSION="0.2.0"
PROG_NAME="$(basename "${BASH_SOURCE[0]}")"

# ─── Utilities ───────────────────────────────────────────────────────────────

die() {
  echo "error: $*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing required command: $1 (install or add to PATH)"
}

print_intro() {
  local project_root="$1"
  local bar
  bar="$(printf '%*s' 68 '' | tr ' ' '=')"
  echo "$bar"
  echo "  $PROG_NAME · Byrde Agents  v$TOOL_VERSION"
  echo ""
  echo "  Install the Figma tool skill into .agents/skills/ and wire up the"
  echo "  Figma MCP server in your editor's project config."
  echo ""
  echo "  One skill, one file: components, tokens, and design work all live"
  echo "  in a single Figma file. The skill overlays on figma-use (Figma's"
  echo "  official plugin-API skill), vendored from upstream on every run."
  echo ""
  printf '  %-16s %s\n' "Project Root" "$project_root"
  printf '  %-16s %s\n' "Layout" "$(layout_describe)"
  printf '  %-16s %s\n' "Auth" "OAuth, in your editor. No token needed here."
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
  printf '  %-16s %s\n' "Team" "${team_name:-$team_id}"
  printf '  %-16s %s\n' "Folder" "$selected_folder_name"
  printf '  %-16s %s\n' "Figma file" "$figma_file_name"
  echo ""
  echo "  Skills:"
  printf '    %s figma-use    %s\n' "✓" "${figma_use_status:-skipped} → $FIGMA_USE_OUT"
  printf '    %s figma        → %s\n' "✓" "$FIGMA_OUT"
  echo ""
  echo "  MCP server:"
  printf '    %-13s %s\n' "Cursor:"      "${cursor_status:-skipped}"
  printf '    %-13s %s\n' "Claude Code:" "${claude_status:-skipped}"
  if [[ "$figma_file_url" == *"not recorded"* ]]; then
    echo ""
    echo "  ⚠  Follow-up — the skill names the file but carries no URL:"
    echo "     1. Open '$figma_file_name' in Figma, under '$selected_folder_name'."
    echo "        Create it first if it does not exist. Add a 'Components' page for"
    echo "        the reusable pieces; design pages get added as work begins."
    echo "     2. Re-run this script and paste the file URL when asked."
  fi
  echo ""
  echo "  Authenticate the MCP server through your editor on first use (OAuth)."
  echo "  Verify with: .agents/scripts/doctor.sh"
  echo "  Undo with:   .agents/scripts/setup/setup-figma.sh uninstall"
  echo "$bar"
}

# ─── Interactive menu (Bash 3.2 safe) ────────────────────────────────────────

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

# ─── Figma API helpers ──────────────────────────────────────────────────────

# GET an endpoint, and SAY WHAT HAPPENED when it fails.
#
# The old body was `curl -sf … 2>/dev/null`. Both halves destroyed evidence:
# `-f` discards the response body on HTTP >= 400, and the redirect discards
# curl's own diagnostics. Every caller was then left printing a guess.
#
# Figma paid for this rule. It retired the scopes `/v1/teams/:id/projects` still
# demands, so a token holding every scope the current UI offers gets a 403 whose
# body names the three accepted scopes exactly. The script reported "check
# permissions or team ID" and sent the reader to look at the team ID, which was
# correct all along.
#
# The body goes to stdout on success. On failure the status and the body go to
# stderr and nothing goes to stdout, so `x="$(figma_get …)" || …` still works.
figma_get() {
  local endpoint="$1"
  local body status

  # `-w` appends the status to the body, so one call yields both without a
  # temporary file. No `-f`: a 4xx body is the part worth reading.
  #
  # `|| true` is load-bearing. The script runs under `set -e`, so a non-zero
  # curl would kill the shell on this assignment — before the reporting below
  # could run, which is the whole point of the function.
  body="$(curl -sS -w $'\n%{http_code}' \
    -H "X-FIGMA-TOKEN: $FIGMA_TOKEN" "$FIGMA_API$endpoint" 2>&1)" || true
  status="${body##*$'\n'}"
  body="${body%$'\n'*}"

  case "$status" in
    2??)
      echo "$body"
      return 0
      ;;
    # `000` is curl's answer when nothing was served — DNS, TLS, refused
    # connection. It is not an HTTP status and must not be reported as one.
    000 | "")
      echo "figma: GET $endpoint did not reach Figma" >&2
      ;;
    [0-9][0-9][0-9])
      echo "figma: GET $endpoint returned HTTP $status" >&2
      ;;
    *)
      echo "figma: GET $endpoint did not complete" >&2
      ;;
  esac

  # Figma answers an error as JSON with a `message`. Print that when it is
  # there, and the raw body when it is not, so an HTML error page is still seen.
  local message=""
  if [[ -n "$body" ]] && command -v jq >/dev/null 2>&1; then
    message="$(echo "$body" | jq -r '.message // .err // empty' 2>/dev/null)"
  fi
  if [[ -n "$message" ]]; then
    echo "figma: $message" >&2
  elif [[ -n "$body" ]]; then
    echo "figma: $body" >&2
  fi

  return 1
}

verify_token() {
  local me
  me="$(figma_get "/v1/me")" || return 1
  local handle
  handle="$(echo "$me" | jq -r '.handle // empty')"
  [[ -n "$handle" ]] || return 1
  echo "$handle"
}

# `list_files` is gone. It read `/v1/projects/:id/files`, which requires the same
# retired scope as the team endpoint, so it cannot succeed for anybody. The file
# name is asked for instead.

get_file_pages() {
  local file_key="$1"
  figma_get "/v1/files/$file_key?depth=1" | jq -r '.document.children[] | .name'
}

extract_team_id() {
  local url="$1"
  # Figma team URLs: https://www.figma.com/files/team/<team_id>/...
  # or: https://www.figma.com/files/<team_id>/...
  local tid
  tid="$(echo "$url" | grep -oE 'team/[0-9]+' | head -1 | sed 's|team/||')"
  if [[ -z "$tid" ]]; then
    # Try extracting a bare numeric ID from the URL path
    tid="$(echo "$url" | grep -oE '/[0-9]{10,}' | head -1 | sed 's|/||')"
  fi
  echo "$tid"
}

# The file key out of a Figma file URL.
#
# Both forms carry it in the same position:
#   https://www.figma.com/design/<key>/<name>
#   https://www.figma.com/file/<key>/<name>
#
# Empty when the URL carries none, which the caller treats as "not recorded"
# rather than an error. The key is a convenience here — the skill records the URL
# as text and the MCP server resolves the file itself.
extract_file_key() {
  local url="$1"
  echo "$url" | sed -nE 's|.*figma\.com/(design\|file)/([A-Za-z0-9]+).*|\2|p' | head -1
}

# ─── Template rendering ─────────────────────────────────────────────────────

install_figma_use() {
  echo ""
  echo "Installing figma-use (Figma's official MCP usage skill) …"

  local tmpdir
  tmpdir="$(mktemp -d)" || die "mktemp failed"

  # shellcheck disable=SC2064
  trap "rm -rf '$tmpdir'" EXIT

  if ! git clone --quiet --depth=1 "$FIGMA_USE_REPO" "$tmpdir/repo" 2>/dev/null; then
    rm -rf "$tmpdir"
    trap - EXIT
    die "failed to clone $FIGMA_USE_REPO — check network or git availability"
  fi

  local src="$tmpdir/repo/$FIGMA_USE_SUBPATH"
  [[ -d "$src" ]] || {
    rm -rf "$tmpdir"
    trap - EXIT
    die "upstream path $FIGMA_USE_SUBPATH missing from $FIGMA_USE_REPO"
  }

  local commit_sha
  commit_sha="$(git -C "$tmpdir/repo" rev-parse HEAD 2>/dev/null || echo unknown)"

  # Replace any existing install so we always reflect upstream
  rm -rf "$FIGMA_USE_OUT"
  mkdir -p "$(dirname "$FIGMA_USE_OUT")"
  cp -R "$src" "$FIGMA_USE_OUT"

  # Write an upstream marker so it's clear where this came from
  cat >"$FIGMA_USE_OUT/.upstream" <<EOF
source: $FIGMA_USE_REPO
path: $FIGMA_USE_SUBPATH
commit: $commit_sha
fetched: $(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF

  figma_use_status="commit ${commit_sha:0:7}"
  echo "  ✓ skills/figma-use/ updated ($figma_use_status)"

  rm -rf "$tmpdir"
  trap - EXIT
}

render_skill() {
  local template="$1" out="$2" team="$3" folder="$4" figma_file="$5"
  [[ -f "$template" ]] || die "missing template: $template"
  mkdir -p "$(dirname "$out")"
  RENDER_TEMPLATE="$template" RENDER_OUT="$out" \
    RENDER_TEAM="$team" RENDER_FOLDER="$folder" \
    RENDER_FIGMA_FILE="$figma_file" \
    python3 <<'PY'
from pathlib import Path
import os
src = Path(os.environ["RENDER_TEMPLATE"])
dst = Path(os.environ["RENDER_OUT"])
text = src.read_text()
# {{PROJECT}} is accepted as well as {{FOLDER}}, so a checkout holding the older
# template still renders instead of shipping a literal placeholder into a skill.
folder = os.environ["RENDER_FOLDER"]
out = (
    text.replace("{{TEAM}}", os.environ["RENDER_TEAM"])
    .replace("{{FOLDER}}", folder)
    .replace("{{PROJECT}}", folder)
    .replace("{{FIGMA_FILE}}", os.environ["RENDER_FIGMA_FILE"])
)
dst.write_text(out)
print("Wrote", dst)
PY
}

# ─── Skill sync ──────────────────────────────────────────────────────────────

# Mirror a skill from .agents/skills/ into the editor-local skill dirs, the
# same way init.sh seeds them. Without this, Claude Code (.claude/skills/) and
# Cursor (.cursor/skills/) never see skills that setup-figma installs.
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

# ─── MCP merging ─────────────────────────────────────────────────────────────

merge_cursor_mcp_figma() {
  local path="$1"
  local tmp
  tmp="$(mktemp)"
  mkdir -p "$(dirname "$path")"
  if [[ -f "$path" ]]; then
    jq '
      .mcpServers = (.mcpServers // {}) |
      .mcpServers.figma = {
        url: "https://mcp.figma.com/mcp"
      }
    ' "$path" >"$tmp" || die "jq failed on $path (invalid JSON?)"
  else
    jq -n '{
      mcpServers: {
        figma: {
          url: "https://mcp.figma.com/mcp"
        }
      }
    }' >"$tmp"
  fi
  mv "$tmp" "$path"
  echo "Updated $path (restart Cursor to reload MCP)"
}

merge_claude_mcp_figma() {
  local path="$1"
  local tmp
  tmp="$(mktemp)"
  mkdir -p "$(dirname "$path")"
  if [[ -f "$path" ]]; then
    jq '
      .mcpServers = (.mcpServers // {}) |
      .mcpServers.figma = {
        type: "http",
        url: "https://mcp.figma.com/mcp"
      }
    ' "$path" >"$tmp" || die "jq failed on $path (invalid JSON?)"
  else
    jq -n '{
      mcpServers: {
        figma: {
          type: "http",
          url: "https://mcp.figma.com/mcp"
        }
      }
    }' >"$tmp"
  fi
  mv "$tmp" "$path"
  echo "Updated $path"
  echo "Restart Claude Code if it is running so MCP picks up changes to $path"
}

# ─── Uninstall ────────────────────────────────────────────────────────────────

# Remove a skill from .agents/skills/ and its editor mirrors. Reverses
# install_figma_use / render_skill + sync_skill_to_editors.
remove_skill() {
  local project_root="$1" skill="$2"
  local found="n"
  [[ -n "$skill" ]] || return 0
  [[ -d "$SKILLS_DIR/$skill" ]] && found="y"
  rm -rf "${SKILLS_DIR:?}/$skill"
  local dest
  for dest in "$project_root/.claude/skills/$skill" "$project_root/.cursor/skills/$skill"; do
    [[ -d "$dest" ]] && found="y"
    rm -rf "$dest"
  done
  [[ "$found" == "y" ]] && echo "  removed $skill"
  return 0
}

# Drop the retired figma-design-system / figma-design-file skills from an
# earlier install, so a re-run doesn't leave two stale skills claiming the
# same operations as `figma`.
remove_legacy_skills() {
  local project_root="$1"
  local skill
  for skill in $LEGACY_SKILLS; do
    remove_skill "$project_root" "$skill"
    manifest_remove "$skill"
  done
}

# Strip the figma MCP server from a JSON config. Reverses the merge_*_figma
# helpers (both write .mcpServers.figma).
remove_mcp_figma() {
  local path="$1"
  [[ -f "$path" ]] || return 0
  jq -e '.mcpServers.figma' "$path" >/dev/null 2>&1 || return 0
  local tmp
  tmp="$(mktemp)"
  if jq 'del(.mcpServers.figma)' "$path" >"$tmp" 2>/dev/null; then
    mv "$tmp" "$path"
    echo "  removed mcpServers.figma from $path"
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
  echo "  Removes the Figma tool skill (including the vendored figma-use) and"
  echo "  the Figma MCP server from your editor configs."
  echo ""
  printf '  %-16s %s\n' "Project Root" "$project_root"
  echo "$bar"
  echo ""

  echo "── Removing skills ──"
  remove_skill "$project_root" "figma"
  remove_skill "$project_root" "figma-use"
  manifest_remove "figma"
  manifest_remove "figma-use"
  remove_legacy_skills "$project_root"
  echo ""

  echo "── Removing MCP registration ──"
  remove_mcp_figma "$cursor_mcp"
  remove_mcp_figma "$claude_mcp"
  echo ""

  echo "$bar"
  echo "  Done. Figma skill and MCP server removed."
  echo "  Restart your editor so it drops the (now-removed) MCP server."
  echo "$bar"
}

# ─── Main ────────────────────────────────────────────────────────────────────

main() {
  case "${1:-}" in
    -h | --help | help)
      echo "$PROG_NAME · Byrde Agents v$TOOL_VERSION"
      echo ""
      echo "Installs the Figma tool skill into .agents/skills/ and merges the"
      echo "Figma MCP server into your editor's project-local config."
      echo ""
      echo "Usage:"
      echo "  cd /your/project && $0              # install"
      echo "  cd /your/project && $0 uninstall    # remove skills + Figma MCP"
      echo ""
      echo "One skill, one Figma file — components, tokens, and design work."
      echo "It overlays on figma-use, vendored from upstream on every run:"
      echo "  https://github.com/figma/mcp-server-guide/tree/main/skills/figma-use"
      echo ""
      echo "Writes:"
      echo "  .agents/skills/figma-use/     — always (refreshed each run)"
      echo "  .agents/skills/figma/SKILL.md"
      echo "  .cursor/mcp.json   — Cursor project MCP"
      echo "  .mcp.json          — Claude Code project MCP"
      exit 0
      ;;
    uninstall | remove)
      uninstall
      exit 0
      ;;
  esac

  require_cmd jq
  require_cmd python3
  require_cmd curl
  require_cmd git

  local project_root
  project_root="$(pwd -P)"
  local cursor_mcp="$project_root/.cursor/mcp.json"
  local claude_mcp="$project_root/.mcp.json"
  local figma_use_status="skipped"

  print_intro "$project_root"

  # In multi-repo mode, keep the per-repo .byrde/ staging out of git.
  ignore_skills_home

  # figma-use is a prerequisite for the overlay — always (re-)install so the
  # vendored copy reflects upstream on every setup run.
  install_figma_use

  # ── Step 1: Name the team, the folder and the file ────────────────────────
  #
  # ## Why this asks instead of looking it up
  #
  # These three values are substituted into the skill's PROSE and nowhere else.
  # No identifier is needed: the MCP server authenticates over OAuth in the
  # editor, and it is the only thing that talks to Figma at run time. A token was
  # never stored by this script — it was read, used for the picker, and dropped.
  #
  # So discovery bought a menu, and it cost a secret paste. Then Figma retired
  # the scopes `/v1/teams/:id/projects` demands, and the menu stopped working for
  # everyone. Asking is now both the reliable path and the one that handles no
  # credential.
  #
  # A token is still honoured when the environment already carries one:
  #
  #   FIGMA_TOKEN=figd_… ./setup-figma.sh
  #
  # That path fills the answers in from the API and falls back to asking when any
  # call fails. It never prompts, because a prompt for a secret this script does
  # not keep is a cost with no return.
  #
  # ## Folder, not Project
  #
  # Figma renamed Projects to Folders in the product. The REST API did NOT: the
  # path is still `/v1/teams/:id/projects` and the field is still `.projects[]`.
  # Human-facing text below says Folder. Every API string keeps the old name,
  # because renaming it would break the call.

  local team_id="" team_name="" selected_folder_name=""
  local figma_file_key="" figma_file_name="" figma_file_url=""
  local discovered="n"

  if [[ -n "${FIGMA_TOKEN:-}" ]]; then
    export FIGMA_TOKEN
    echo ""
    echo "FIGMA_TOKEN is set — trying to read the team from the API."
    echo "Any failure below falls back to typing the names in. Nothing is stored."
    echo ""

    local handle
    if handle="$(verify_token)"; then
      echo "Authenticated as: $handle"
      discovered="y"
    else
      echo "The token did not verify. Falling back to typing the names in." >&2
      discovered="n"
    fi
  fi

  if [[ "$discovered" == "y" ]]; then
    echo ""
    echo "Figma provides no API to list your teams."
    echo "Open the team in Figma's file browser and copy the URL."
    echo "Example: https://www.figma.com/files/team/1234567890/My-Team"
    echo ""
    local team_url
    read -r -p "Paste your Figma team URL: " team_url || die "stdin closed"
    team_id="$(extract_team_id "$team_url")"
    [[ -n "$team_id" ]] || die "could not read a team ID from: $team_url"
    echo "Team ID: $team_id"

    # `/projects` is Figma's path, not our word. See the note above.
    echo "Reading the team's folders …"
    local folders_raw=""
    if folders_raw="$(figma_get "/v1/teams/$team_id/projects")"; then
      team_name="$(echo "$folders_raw" | jq -r '.name // empty')"
      local folder_names=()
      while IFS= read -r fname || [[ -n "$fname" ]]; do
        [[ -n "$fname" ]] && folder_names+=("$fname")
      done < <(echo "$folders_raw" | jq -r '.projects[]?.name')

      if [[ ${#folder_names[@]} -gt 0 ]]; then
        selected_folder_name="$(pick_from_menu "Folders in this team:" "${folder_names[@]}")"
      else
        echo "The team reports no folders. Falling back to typing the names in." >&2
        discovered="n"
      fi
    else
      # `figma_get` already printed the status and Figma's own message, so this
      # adds only what to do about it. Never restate the cause — a guess here is
      # what made the original failure unreadable.
      echo ""
      echo "Could not read the team's folders. The message above is Figma's." >&2
      echo "Falling back to typing the names in — the install does not need the API." >&2
      discovered="n"
    fi
  fi

  if [[ "$discovered" != "y" ]]; then
    echo ""
    echo "Name the Figma team, folder and file this project designs in."
    echo "These go into the skill as text, so type them as Figma shows them."
    echo "Figma calls a folder a Folder — it was called a Project until 2025."
    echo ""

    read -r -p "Team name: " team_name || die "stdin closed"
    [[ -n "$team_name" ]] || die "a team name is required"

    read -r -p "Folder name: " selected_folder_name || die "stdin closed"
    [[ -n "$selected_folder_name" ]] || die "a folder name is required"

    read -r -p "File name: " figma_file_name || die "stdin closed"
    [[ -n "$figma_file_name" ]] || die "a file name is required"

    echo ""
    echo "Paste the file's URL to record it in the skill, or press enter to skip."
    read -r -p "File URL: " figma_file_url || true
    if [[ -n "$figma_file_url" ]]; then
      figma_file_key="$(extract_file_key "$figma_file_url")"
    else
      figma_file_url="(not recorded — paste the file URL on a later run)"
    fi
  fi

  # ── Step 2: Name the file, when the API supplied the folder ───────────────

  if [[ "$discovered" == "y" && -z "$figma_file_name" ]]; then
    echo ""
    echo "Name the file inside '$selected_folder_name' that holds the components"
    echo "and the design work. One file, not one per surface."
    echo ""
    read -r -p "File name: " figma_file_name || die "stdin closed"
    [[ -n "$figma_file_name" ]] || figma_file_name="Design"

    read -r -p "File URL (enter to skip): " figma_file_url || true
    if [[ -n "$figma_file_url" ]]; then
      figma_file_key="$(extract_file_key "$figma_file_url")"
    else
      figma_file_url="(not recorded — paste the file URL on a later run)"
    fi
  fi

  # Informational only. The file's page structure is the team's business, and
  # this needs `file_content:read`, which the current scopes DO grant.
  if [[ -n "$figma_file_key" && -n "${FIGMA_TOKEN:-}" ]]; then
    local -a existing_pages=()
    while IFS= read -r pg || [[ -n "$pg" ]]; do
      [[ -n "$pg" ]] && existing_pages+=("$pg")
    done < <(get_file_pages "$figma_file_key" 2>/dev/null)

    if [[ ${#existing_pages[@]} -gt 0 ]]; then
      echo ""
      echo "  Pages in '$figma_file_name':"
      local ep has_components="n"
      for ep in "${existing_pages[@]}"; do
        echo "    • $ep"
        [[ "$ep" == "Components" ]] && has_components="y"
      done
      if [[ "$has_components" == "n" ]]; then
        echo ""
        echo "  Note: no 'Components' page yet — add one for the reusable"
        echo "  pieces, or have an agent create it in your first session."
      fi
    fi
  fi

  # ── Step 5: Render the skill ──────────────────────────────────────────────

  # The ID is recorded only when the API supplied one. A manual install has no
  # team ID and does not need one, so it must not render "(ID: )".
  local team_field="$team_name"
  [[ -n "$team_id" ]] && team_field="$team_name (ID: $team_id)"
  [[ -n "$team_field" ]] || team_field="$team_id"
  local figma_field="$figma_file_name — $figma_file_url"

  render_skill "$FIGMA_TEMPLATE" "$FIGMA_OUT" \
    "$team_field" "$selected_folder_name" "$figma_field"

  # ── Step 5b: Sync skills into editor dirs ────────────────────────────────
  # .agents/skills/ is the source of truth; init.sh mirrors it into the
  # editor-local skill dirs. setup-figma writes new skills, so mirror the
  # ones we just installed so Claude Code and Cursor can pick them up.
  sync_skill_to_editors "$project_root" "figma-use"
  manifest_add "figma-use"
  sync_skill_to_editors "$project_root" "figma"
  manifest_add "figma"

  # Clear out figma-design-system / figma-design-file from an earlier install.
  remove_legacy_skills "$project_root"

  # ── Step 6: Merge MCP ────────────────────────────────────────────────────

  local cursor_status="skipped"
  local claude_status="skipped"

  echo ""
  echo "The Figma MCP server uses OAuth — authentication happens interactively"
  echo "through your MCP client (Cursor, Claude Code) on first use."
  echo ""

  read -r -p "Merge Figma MCP into $cursor_mcp? [Y/n] " a_cursor
  if [[ "${a_cursor:-y}" =~ ^[Yy]|^$ ]]; then
    merge_cursor_mcp_figma "$cursor_mcp"
    cursor_status="merged → $cursor_mcp"
  fi

  echo ""
  read -r -p "Merge Figma MCP into $claude_mcp (Claude Code project MCP)? [Y/n] " a_claude
  if [[ "${a_claude:-y}" =~ ^[Yy]|^$ ]]; then
    merge_claude_mcp_figma "$claude_mcp"
    claude_status="merged → $claude_mcp"
  fi

  print_summary
}

# `SETUP_FIGMA_SOURCED_ONLY=1` lets a test source this file and call one
# function. Without it, sourcing starts the installer — which is how a test suite
# ends up prompting for a token and writing config into a sandbox.
if [[ -z "${SETUP_FIGMA_SOURCED_ONLY:-}" ]]; then
  main "$@"
fi
