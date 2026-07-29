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
  printf '  %-16s %s\n' "Auth" "Figma Personal Access Token"
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
  printf '  %-16s %s\n' "Project" "$selected_project_name"
  printf '  %-16s %s\n' "Figma file" "$figma_file_name"
  echo ""
  echo "  Skills:"
  printf '    %s figma-use    %s\n' "✓" "${figma_use_status:-skipped} → $FIGMA_USE_OUT"
  printf '    %s figma        → %s\n' "✓" "$FIGMA_OUT"
  echo ""
  echo "  MCP server:"
  printf '    %-13s %s\n' "Cursor:"      "${cursor_status:-skipped}"
  printf '    %-13s %s\n' "Claude Code:" "${claude_status:-skipped}"
  if [[ "$figma_file_url" == *"pending"* ]]; then
    echo ""
    echo "  ⚠  Follow-up — the Figma file is pending:"
    echo "     1. Create '$figma_file_name' in Figma inside '$selected_project_name'."
    echo "     2. Add a 'Components' page for the reusable pieces. Design pages"
    echo "        get added as work begins — nothing else is required up front."
    echo "     3. Re-run this script to update the file reference."
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

figma_get() {
  local endpoint="$1"
  local response
  response="$(curl -sf -H "X-FIGMA-TOKEN: $FIGMA_TOKEN" "$FIGMA_API$endpoint" 2>/dev/null)" \
    || return 1
  echo "$response"
}

verify_token() {
  local me
  me="$(figma_get "/v1/me")" || return 1
  local handle
  handle="$(echo "$me" | jq -r '.handle // empty')"
  [[ -n "$handle" ]] || return 1
  echo "$handle"
}

list_files() {
  local project_id="$1"
  figma_get "/v1/projects/$project_id/files" | jq -r '.files[] | "\(.key)\t\(.name)"'
}

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
  local template="$1" out="$2" team="$3" project="$4" figma_file="$5"
  [[ -f "$template" ]] || die "missing template: $template"
  mkdir -p "$(dirname "$out")"
  RENDER_TEMPLATE="$template" RENDER_OUT="$out" \
    RENDER_TEAM="$team" RENDER_PROJECT="$project" \
    RENDER_FIGMA_FILE="$figma_file" \
    python3 <<'PY'
from pathlib import Path
import os
src = Path(os.environ["RENDER_TEMPLATE"])
dst = Path(os.environ["RENDER_OUT"])
text = src.read_text()
out = (
    text.replace("{{TEAM}}", os.environ["RENDER_TEAM"])
    .replace("{{PROJECT}}", os.environ["RENDER_PROJECT"])
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

  # ── Step 1: Authenticate ──────────────────────────────────────────────────

  echo ""
  echo "A Figma Personal Access Token is required."
  echo "Generate one at: https://www.figma.com/developers/api#access-tokens"
  echo "Required scopes: file_content:read, projects:read"
  echo ""

  local FIGMA_TOKEN
  read -r -s -p "Paste your Figma Personal Access Token: " FIGMA_TOKEN || die "stdin closed"
  echo ""
  export FIGMA_TOKEN

  echo "Verifying token …"
  local handle
  handle="$(verify_token)" || die "authentication failed — token is invalid or expired"
  echo "Authenticated as: $handle"

  # ── Step 2: Get Team ID ───────────────────────────────────────────────────

  echo ""
  echo "Figma does not provide an API to list your teams."
  echo "Navigate to your team in Figma's file browser and copy the URL."
  echo "Example: https://www.figma.com/files/team/1234567890/My-Team"
  echo ""

  local team_url team_id
  read -r -p "Paste your Figma team URL: " team_url || die "stdin closed"
  team_id="$(extract_team_id "$team_url")"
  [[ -n "$team_id" ]] || die "could not extract team ID from URL: $team_url"

  echo "Extracted team ID: $team_id"

  # Verify the team ID works by listing projects
  echo "Verifying team access …"
  local projects_raw
  projects_raw="$(figma_get "/v1/teams/$team_id/projects")" \
    || die "cannot access team $team_id — check permissions or team ID"

  local team_name
  team_name="$(echo "$projects_raw" | jq -r '.name // empty')"
  if [[ -n "$team_name" ]]; then
    echo "Team: $team_name"
  fi

  # ── Step 3: Select Project ────────────────────────────────────────────────

  local project_ids=()
  local project_names=()
  while IFS=$'\t' read -r pid pname || [[ -n "$pid" ]]; do
    [[ -n "$pid" ]] || continue
    project_ids+=("$pid")
    project_names+=("$pname")
  done < <(echo "$projects_raw" | jq -r '.projects[] | "\(.id)\t\(.name)"')

  [[ ${#project_names[@]} -gt 0 ]] || die "no projects found in team $team_id"

  local selected_project_name
  selected_project_name="$(pick_from_menu "Projects in this team:" "${project_names[@]}")"

  local selected_project_id=""
  local idx=0
  for pn in "${project_names[@]}"; do
    if [[ "$pn" == "$selected_project_name" ]]; then
      selected_project_id="${project_ids[$idx]}"
      break
    fi
    ((idx++)) || true
  done
  [[ -n "$selected_project_id" ]] || die "internal error: project ID not found"

  echo "Selected project: $selected_project_name (ID: $selected_project_id)"

  # ── Step 4: Select the project's Figma file ───────────────────────────────
  # One file holds components, tokens, and design work. Pages inside it are the
  # team's business — nothing is validated or required here.

  local figma_file_key="" figma_file_name="" figma_file_url=""

  echo ""
  echo "Listing files in project '$selected_project_name' …"

  local file_keys=()
  local file_names=()
  while IFS=$'\t' read -r fkey fname || [[ -n "$fkey" ]]; do
    [[ -n "$fkey" ]] || continue
    file_keys+=("$fkey")
    file_names+=("$fname")
  done < <(list_files "$selected_project_id")

  if [[ ${#file_names[@]} -eq 0 ]]; then
    echo ""
    echo "No files found in this project."
    echo "You will need to create the design file in Figma and re-run this script."
    echo ""
    read -r -p "Enter the name for your future Figma file: " figma_file_name || true
    [[ -n "$figma_file_name" ]] || figma_file_name="Design"
    figma_file_url="(pending — create the file in Figma, then re-run setup)"
  else
    local -a file_display=()
    for fn in "${file_names[@]}"; do
      file_display+=("$fn")
    done

    echo ""
    echo "Select the file that is (or will be) this project's design file —"
    echo "one file holding the reusable components and the design work."
    echo "If it doesn't exist yet, choose 'Create new …' and set it up in Figma."
    file_display+=("[Create new — I'll set it up in Figma]")

    local selected_file_display
    selected_file_display="$(pick_from_menu "Files in '$selected_project_name':" "${file_display[@]}")"

    if [[ "$selected_file_display" == "[Create new — I'll set it up in Figma]" ]]; then
      read -r -p "Enter the name for your Figma file: " figma_file_name || true
      [[ -n "$figma_file_name" ]] || figma_file_name="Design"
      figma_file_url="(pending — create the file in Figma, then re-run setup)"
    else
      figma_file_name="$selected_file_display"
      local fidx=0
      for fn in "${file_names[@]}"; do
        if [[ "$fn" == "$figma_file_name" ]]; then
          figma_file_key="${file_keys[$fidx]}"
          break
        fi
        ((fidx++)) || true
      done
      figma_file_url="https://www.figma.com/design/$figma_file_key"

      # Informational only — the file's page structure is not prescribed.
      local -a existing_pages=()
      while IFS= read -r pg || [[ -n "$pg" ]]; do
        [[ -n "$pg" ]] && existing_pages+=("$pg")
      done < <(get_file_pages "$figma_file_key")

      if [[ ${#existing_pages[@]} -gt 0 ]]; then
        echo ""
        echo "  Current pages in '$figma_file_name':"
        for ep in "${existing_pages[@]}"; do
          echo "    • $ep"
        done
        local has_components="n"
        for ep in "${existing_pages[@]}"; do
          [[ "$ep" == "Components" ]] && has_components="y"
        done
        if [[ "$has_components" == "n" ]]; then
          echo ""
          echo "  Note: no 'Components' page yet — add one for the reusable"
          echo "  pieces, or have an agent create it in your first session."
        fi
      fi
    fi
  fi

  # ── Step 5: Render the skill ──────────────────────────────────────────────

  local team_field="${team_name:-$team_id} (ID: $team_id)"
  local figma_field="$figma_file_name — $figma_file_url"

  render_skill "$FIGMA_TEMPLATE" "$FIGMA_OUT" \
    "$team_field" "$selected_project_name" "$figma_field"

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

main "$@"
