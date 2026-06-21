#!/usr/bin/env bash
# Configure the Figma tool skills: render per-capability templates into
# .agents/skills/ and merge the Figma MCP server into project-local configs.
#
# Two opt-in capabilities:
#   - figma-design-system   → tokens, components, library publishing
#   - figma-design-file     → one shared design file, organised by pages
# Pick either, both, or neither.
#
# Run from the repository/project root you want to configure (current working
# directory).
#
# Writes (per opted-in capability):
#   - .agents/skills/figma-design-system/SKILL.md
#   - .agents/skills/figma-design-file/SKILL.md
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
DESIGN_SYSTEM_TEMPLATE="$TOOL_DIR/figma-design-system.md.template"
DESIGN_SYSTEM_OUT="$SKILLS_DIR/figma-design-system/SKILL.md"
DESIGN_FILE_TEMPLATE="$TOOL_DIR/figma-design-file.md.template"
DESIGN_FILE_OUT="$SKILLS_DIR/figma-design-file/SKILL.md"

# Upstream figma-use skill — vendored from Figma's official MCP guide.
# Our skills overlay on top of this; it owns the plugin-API mechanics.
FIGMA_USE_REPO="https://github.com/figma/mcp-server-guide.git"
FIGMA_USE_SUBPATH="skills/figma-use"
FIGMA_USE_OUT="$SKILLS_DIR/figma-use"

FIGMA_API="https://api.figma.com"
FIGMA_MCP_URL="https://mcp.figma.com/mcp"

TOOL_VERSION="0.1.0"
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
  echo "  Install Figma tool skills into .agents/skills/ and wire up the"
  echo "  Figma MCP server in your editor's project config."
  echo ""
  echo "  Two opt-in capabilities — install either, both, or neither:"
  echo "    • figma-design-system   tokens, components, library publishing"
  echo "    • figma-design-file     one shared design file, organised by pages"
  echo ""
  echo "  Both overlay on figma-use (Figma's official plugin-API skill),"
  echo "  which is vendored from upstream on every run."
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
  if [[ "$install_ds" == "y" ]]; then
    printf '  %-16s %s\n' "Design System" "$ds_file_name"
  fi
  if [[ "$install_df" == "y" ]]; then
    printf '  %-16s %s\n' "Design File" "$design_file_name"
  fi
  echo ""
  echo "  Skills:"
  printf '    %s figma-use              %s\n' "✓" "${figma_use_status:-skipped} → $FIGMA_USE_OUT"
  if [[ "$install_ds" == "y" ]]; then
    echo "    ✓ figma-design-system    → $DESIGN_SYSTEM_OUT"
  else
    echo "    - figma-design-system    (declined)"
  fi
  if [[ "$install_df" == "y" ]]; then
    echo "    ✓ figma-design-file      → $DESIGN_FILE_OUT"
  else
    echo "    - figma-design-file      (declined)"
  fi
  echo ""
  echo "  MCP server:"
  printf '    %-13s %s\n' "Cursor:"      "${cursor_status:-skipped}"
  printf '    %-13s %s\n' "Claude Code:" "${claude_status:-skipped}"
  if [[ "$install_ds" == "y" && "$ds_file_url" == *"pending"* ]]; then
    echo ""
    echo "  ⚠  Follow-up — Design System file is pending:"
    echo "     1. Create '$ds_file_name' in Figma inside '$selected_project_name'."
    echo "     2. Add the suggested pages: Cover, Components, Typography,"
    echo "        Colors, Spacing, Icons. (Logos optional. Flat structure —"
    echo "        no atomic hierarchy.)"
    echo "     3. Publish it as a team library."
    echo "     4. Re-run this script to update the file reference."
  fi
  if [[ "$install_df" == "y" && "$design_file_url" == *"pending"* ]]; then
    echo ""
    echo "  ⚠  Follow-up — Design file is pending:"
    echo "     1. Create '$design_file_name' in Figma inside '$selected_project_name'."
    echo "     2. Add a Cover page and an Archive page; add design pages"
    echo "        (one per screen, or one per feature) as work begins."
    echo "     3. Re-run this script to update the file reference."
  fi
  echo ""
  echo "  Authenticate the MCP server through your editor on first use (OAuth)."
  echo "  Verify with: .agents/scripts/doctor.sh"
  echo "  Undo with:   .agents/scripts/setup-figma.sh uninstall"
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

list_projects() {
  local team_id="$1"
  figma_get "/v1/teams/$team_id/projects" | jq -r '.projects[] | "\(.id)\t\(.name)"'
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
  # Renders any Figma skill template. Both file placeholders are substituted;
  # each template uses only the one it references, so the other is harmless.
  local template="$1" out="$2" team="$3" project="$4" ds_file="$5" design_file="${6:-}"
  [[ -f "$template" ]] || die "missing template: $template"
  mkdir -p "$(dirname "$out")"
  RENDER_TEMPLATE="$template" RENDER_OUT="$out" \
    RENDER_TEAM="$team" RENDER_PROJECT="$project" \
    RENDER_DS_FILE="$ds_file" RENDER_DESIGN_FILE="$design_file" \
    python3 <<'PY'
from pathlib import Path
import os
src = Path(os.environ["RENDER_TEMPLATE"])
dst = Path(os.environ["RENDER_OUT"])
text = src.read_text()
out = (
    text.replace("{{TEAM}}", os.environ["RENDER_TEAM"])
    .replace("{{PROJECT}}", os.environ["RENDER_PROJECT"])
    .replace("{{DESIGN_SYSTEM_FILE}}", os.environ["RENDER_DS_FILE"])
    .replace("{{DESIGN_FILE}}", os.environ["RENDER_DESIGN_FILE"])
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
  rm -rf "$SKILLS_DIR/$skill"
  echo "  removed skills/$skill"
  local dest
  for dest in "$project_root/.claude/skills/$skill" "$project_root/.cursor/skills/$skill"; do
    rm -rf "$dest"
    echo "  removed ${dest#$project_root/}"
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
  echo "  Removes the Figma tool skills (including the vendored figma-use) and"
  echo "  the Figma MCP server from your editor configs."
  echo ""
  printf '  %-16s %s\n' "Project Root" "$project_root"
  echo "$bar"
  echo ""

  echo "── Removing skills ──"
  remove_skill "$project_root" "figma-design-system"
  remove_skill "$project_root" "figma-design-file"
  remove_skill "$project_root" "figma-use"
  manifest_remove "figma-design-system"
  manifest_remove "figma-design-file"
  manifest_remove "figma-use"
  echo ""

  echo "── Removing MCP registration ──"
  remove_mcp_figma "$cursor_mcp"
  remove_mcp_figma "$claude_mcp"
  echo ""

  echo "$bar"
  echo "  Done. Figma skills and MCP server removed."
  echo "  Restart your editor so it drops the (now-removed) MCP server."
  echo "$bar"
}

# ─── Main ────────────────────────────────────────────────────────────────────

main() {
  case "${1:-}" in
    -h | --help | help)
      echo "$PROG_NAME · Byrde Agents v$TOOL_VERSION"
      echo ""
      echo "Installs Figma tool skills into .agents/skills/ and merges the"
      echo "Figma MCP server into your editor's project-local config."
      echo ""
      echo "Usage:"
      echo "  cd /your/project && $0              # install"
      echo "  cd /your/project && $0 uninstall    # remove skills + Figma MCP"
      echo ""
      echo "Opt-in capabilities (pick either, both, or neither):"
      echo "  figma-design-system   tokens, components, library publishing"
      echo "  figma-design-file     one shared design file, organised by pages"
      echo ""
      echo "Both overlay on figma-use, vendored from upstream on every run:"
      echo "  https://github.com/figma/mcp-server-guide/tree/main/skills/figma-use"
      echo ""
      echo "Writes:"
      echo "  .agents/skills/figma-use/                — always (refreshed each run)"
      echo "  .agents/skills/figma-design-system/SKILL.md  — per opt-in"
      echo "  .agents/skills/figma-design-file/SKILL.md  — per opt-in"
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

  print_intro "$project_root"

  # ── Step 0: Capability selection ─────────────────────────────────────────
  local install_ds="n" install_df="n"
  local figma_use_status="skipped"
  echo "Which Figma capabilities should be installed as skills?"
  echo ""
  read -r -p "Install figma-design-system (tokens, components, library)? [Y/n] " a_ds
  [[ "${a_ds:-y}" =~ ^[Yy]|^$ ]] && install_ds="y"
  read -r -p "Install figma-design-file (one shared design file, organised by pages)? [Y/n] " a_df
  [[ "${a_df:-y}" =~ ^[Yy]|^$ ]] && install_df="y"

  if [[ "$install_ds" != "y" && "$install_df" != "y" ]]; then
    echo ""
    echo "Nothing selected — exiting without changes."
    exit 0
  fi

  # In multi-repo mode, keep the per-repo .byrde/ staging out of git.
  ignore_skills_home

  # figma-use is a prerequisite for the Figma overlays — always (re-)install
  # so the vendored copy reflects upstream on every setup run.
  install_figma_use

  # ── Step 1: Authenticate ──────────────────────────────────────────────────

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

  # ── Step 4: Select or identify Design System file (only if installing it) ─

  local ds_file_key="" ds_file_name="" ds_file_url=""

  if [[ "$install_ds" != "y" ]]; then
    ds_file_name="N/A"
    ds_file_url="N/A (figma-design-system not installed)"
  else

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
    echo "You will need to create a Design System file in Figma and re-run this script."
    echo ""
    read -r -p "Enter the name for your future Design System file: " ds_file_name || true
    [[ -n "$ds_file_name" ]] || ds_file_name="Design System"
    ds_file_url="(pending — create the file in Figma, then re-run setup)"
  else
    local -a file_display=()
    for fn in "${file_names[@]}"; do
      file_display+=("$fn")
    done

    echo ""
    echo "Select the file that is (or will be) your Design System library."
    echo "If it doesn't exist yet, choose 'Create new …' and set it up in Figma."
    file_display+=("[Create new — I'll set it up in Figma]")

    local selected_file_display
    selected_file_display="$(pick_from_menu "Files in '$selected_project_name':" "${file_display[@]}")"

    if [[ "$selected_file_display" == "[Create new — I'll set it up in Figma]" ]]; then
      read -r -p "Enter the name for your Design System file: " ds_file_name || true
      [[ -n "$ds_file_name" ]] || ds_file_name="Design System"
      ds_file_url="(pending — create the file in Figma, then re-run setup)"
    else
      ds_file_name="$selected_file_display"
      local fidx=0
      for fn in "${file_names[@]}"; do
        if [[ "$fn" == "$ds_file_name" ]]; then
          ds_file_key="${file_keys[$fidx]}"
          break
        fi
        ((fidx++)) || true
      done
      ds_file_url="https://www.figma.com/design/$ds_file_key"

      # Validate page structure
      echo ""
      echo "Checking Design System file structure …"
      local -a existing_pages=()
      while IFS= read -r pg || [[ -n "$pg" ]]; do
        [[ -n "$pg" ]] && existing_pages+=("$pg")
      done < <(get_file_pages "$ds_file_key")

      local -a required_pages=("Cover" "Components" "Typography" "Colors" "Spacing" "Icons")
      local -a missing_pages=()
      for rp in "${required_pages[@]}"; do
        local found=false
        for ep in "${existing_pages[@]}"; do
          if [[ "$ep" == "$rp" ]]; then
            found=true
            break
          fi
        done
        if [[ "$found" == "false" ]]; then
          missing_pages+=("$rp")
        fi
      done

      if [[ ${#missing_pages[@]} -eq 0 ]]; then
        echo "  ✓ All required pages present: ${required_pages[*]}"
      else
        echo "  ⚠ Missing pages: ${missing_pages[*]}"
        echo "  The following pages need to be created in the Design System file:"
        for mp in "${missing_pages[@]}"; do
          echo "    - $mp"
        done
        echo ""
        echo "  You can create these pages manually in Figma, or have an agent"
        echo "  create them via the MCP server in your first design session."
      fi

      if [[ ${#existing_pages[@]} -gt 0 ]]; then
        echo ""
        echo "  Current pages in '$ds_file_name':"
        for ep in "${existing_pages[@]}"; do
          echo "    • $ep"
        done
      fi
    fi
  fi

  fi # end: install_ds gate

  # ── Step 4b: Select or identify the Design file (only if installing it) ───
  # The design file is one shared file for the project, organised by pages —
  # pinned here the same way the Design System file is. No required-page
  # validation: pages (one per screen, or one per feature) are added as work
  # begins; only a Cover and an Archive page are expected up front.

  local design_file_key="" design_file_name="" design_file_url=""

  if [[ "$install_df" != "y" ]]; then
    design_file_name="N/A"
    design_file_url="N/A (figma-design-file not installed)"
  else

  echo ""
  echo "Listing files in project '$selected_project_name' …"

  local df_file_keys=()
  local df_file_names=()
  while IFS=$'\t' read -r fkey fname || [[ -n "$fkey" ]]; do
    [[ -n "$fkey" ]] || continue
    df_file_keys+=("$fkey")
    df_file_names+=("$fname")
  done < <(list_files "$selected_project_id")

  if [[ ${#df_file_names[@]} -eq 0 ]]; then
    echo ""
    echo "No files found in this project."
    echo "You will need to create a design file in Figma and re-run this script."
    echo ""
    read -r -p "Enter the name for your future design file: " design_file_name || true
    [[ -n "$design_file_name" ]] || design_file_name="Designs"
    design_file_url="(pending — create the file in Figma, then re-run setup)"
  else
    local -a df_file_display=()
    for fn in "${df_file_names[@]}"; do
      df_file_display+=("$fn")
    done

    echo ""
    echo "Select the file that is (or will be) your shared design file —"
    echo "where design work lives, organised by pages (one per screen, or"
    echo "one per feature). This is distinct from the Design System library."
    echo "If it doesn't exist yet, choose 'Create new …' and set it up in Figma."
    df_file_display+=("[Create new — I'll set it up in Figma]")

    local df_selected_display
    df_selected_display="$(pick_from_menu "Files in '$selected_project_name':" "${df_file_display[@]}")"

    if [[ "$df_selected_display" == "[Create new — I'll set it up in Figma]" ]]; then
      read -r -p "Enter the name for your design file: " design_file_name || true
      [[ -n "$design_file_name" ]] || design_file_name="Designs"
      design_file_url="(pending — create the file in Figma, then re-run setup)"
    else
      design_file_name="$df_selected_display"
      local dfidx=0
      for fn in "${df_file_names[@]}"; do
        if [[ "$fn" == "$design_file_name" ]]; then
          design_file_key="${df_file_keys[$dfidx]}"
          break
        fi
        ((dfidx++)) || true
      done
      design_file_url="https://www.figma.com/design/$design_file_key"

      # Show current pages (informational — no required-page validation)
      local -a df_existing_pages=()
      while IFS= read -r pg || [[ -n "$pg" ]]; do
        [[ -n "$pg" ]] && df_existing_pages+=("$pg")
      done < <(get_file_pages "$design_file_key")

      if [[ ${#df_existing_pages[@]} -gt 0 ]]; then
        echo ""
        echo "  Current pages in '$design_file_name':"
        for ep in "${df_existing_pages[@]}"; do
          echo "    • $ep"
        done
      fi
    fi
  fi

  fi # end: install_df gate

  # ── Step 5: Render skills ─────────────────────────────────────────────────

  local team_field="${team_name:-$team_id} (ID: $team_id)"
  local ds_field="$ds_file_name — $ds_file_url"
  local design_field="$design_file_name — $design_file_url"

  if [[ "$install_ds" == "y" ]]; then
    render_skill "$DESIGN_SYSTEM_TEMPLATE" "$DESIGN_SYSTEM_OUT" \
      "$team_field" "$selected_project_name" "$ds_field"
  fi
  if [[ "$install_df" == "y" ]]; then
    render_skill "$DESIGN_FILE_TEMPLATE" "$DESIGN_FILE_OUT" \
      "$team_field" "$selected_project_name" "$ds_field" "$design_field"
  fi

  # ── Step 5b: Sync skills into editor dirs ────────────────────────────────
  # .agents/skills/ is the source of truth; init.sh mirrors it into the
  # editor-local skill dirs. setup-figma writes new skills, so mirror the
  # ones we just installed so Claude Code and Cursor can pick them up.
  sync_skill_to_editors "$project_root" "figma-use"
  manifest_add "figma-use"
  if [[ "$install_ds" == "y" ]]; then
    sync_skill_to_editors "$project_root" "figma-design-system"
    manifest_add "figma-design-system"
  fi
  if [[ "$install_df" == "y" ]]; then
    sync_skill_to_editors "$project_root" "figma-design-file"
    manifest_add "figma-design-file"
  fi

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
