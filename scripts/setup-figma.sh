#!/usr/bin/env bash
# Configure the Figma tool: .agents/tools/figma.md from template + project-local MCP.
#
# Run from the repository/project root you want to configure (current working directory).
# Writes:
#   - .agents/tools/figma.md   — rendered from figma.md.template
#   - .cursor/mcp.json         — Cursor project MCP (Figma server merged in)
#   - .mcp.json                — Claude Code project MCP (Figma server merged in)
#
# Does not modify $HOME. Does not invoke the cursor or claude CLIs; only merges JSON with jq.
#
# Usage: cd /path/to/project && /path/to/setup-figma.sh
#
# Requires: jq, python3, curl
# Compatible with Bash 3.2 (macOS): no mapfile/readarray.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENTS_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TOOL_DIR="$AGENTS_ROOT/tools"
FIGMA_TEMPLATE="$TOOL_DIR/figma.md.template"
FIGMA_OUT="$TOOL_DIR/figma.md"

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
  echo "  Configure the Figma agent tool for this project: interactive picker"
  echo "  (Figma REST API), then render .agents/tools/figma.md and merge the"
  echo "  Figma MCP server into project-local .cursor/mcp.json and .mcp.json."
  echo ""
  printf '  %-16s %s\n' "Project Root" "$project_root"
  printf '  %-16s %s\n' "Auth" "Figma Personal Access Token"
  echo "$bar"
  echo ""
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

render_figma_md() {
  local team="$1" project="$2" ds_file="$3"
  [[ -f "$FIGMA_TEMPLATE" ]] || die "missing template: $FIGMA_TEMPLATE"
  FIGMA_TEMPLATE="$FIGMA_TEMPLATE" FIGMA_OUT="$FIGMA_OUT" \
    RENDER_TEAM="$team" RENDER_PROJECT="$project" RENDER_DS_FILE="$ds_file" \
    python3 <<'PY'
from pathlib import Path
import os
src = Path(os.environ["FIGMA_TEMPLATE"])
dst = Path(os.environ["FIGMA_OUT"])
text = src.read_text()
out = (
    text.replace("{{TEAM}}", os.environ["RENDER_TEAM"])
    .replace("{{PROJECT}}", os.environ["RENDER_PROJECT"])
    .replace("{{DESIGN_SYSTEM_FILE}}", os.environ["RENDER_DS_FILE"])
)
dst.write_text(out)
print("Wrote", dst)
PY
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

# ─── Main ────────────────────────────────────────────────────────────────────

main() {
  case "${1:-}" in
    -h | --help | help)
      echo "$PROG_NAME · Byrde Agents v$TOOL_VERSION"
      echo ""
      echo "Usage:"
      echo "  cd /your/project && $0"
      echo ""
      echo "Writes:"
      echo "  .agents/tools/figma.md      — from figma.md.template"
      echo "  .cursor/mcp.json            — Cursor project MCP"
      echo "  .mcp.json                   — Claude Code project MCP"
      exit 0
      ;;
  esac

  require_cmd jq
  require_cmd python3
  require_cmd curl

  local project_root
  project_root="$(pwd -P)"
  local cursor_mcp="$project_root/.cursor/mcp.json"
  local claude_mcp="$project_root/.mcp.json"

  print_intro "$project_root"

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

  # ── Step 4: Select or identify Design System file ─────────────────────────

  echo ""
  echo "Listing files in project '$selected_project_name' …"

  local file_keys=()
  local file_names=()
  while IFS=$'\t' read -r fkey fname || [[ -n "$fkey" ]]; do
    [[ -n "$fkey" ]] || continue
    file_keys+=("$fkey")
    file_names+=("$fname")
  done < <(list_files "$selected_project_id")

  local ds_file_key="" ds_file_name="" ds_file_url=""

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

      local -a required_pages=("Cover" "Foundations" "Atoms" "Molecules" "Organisms")
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

  # ── Step 5: Render template ───────────────────────────────────────────────

  echo ""
  echo "Configuration summary:"
  echo "  Team:               ${team_name:-$team_id}"
  echo "  Project:            $selected_project_name"
  echo "  Design System File: $ds_file_name"
  if [[ -n "$ds_file_key" ]]; then
    echo "  Design System URL:  $ds_file_url"
  fi
  echo ""

  local team_field="${team_name:-$team_id} (ID: $team_id)"
  local ds_field="$ds_file_name — $ds_file_url"

  render_figma_md "$team_field" "$selected_project_name" "$ds_field"

  # ── Step 6: Merge MCP ────────────────────────────────────────────────────

  echo ""
  echo "The Figma MCP server uses OAuth — authentication happens interactively"
  echo "through your MCP client (Cursor, Claude Code) on first use."
  echo ""

  read -r -p "Merge Figma MCP into $cursor_mcp? [Y/n] " a_cursor
  if [[ "${a_cursor:-y}" =~ ^[Yy]|^$ ]]; then
    merge_cursor_mcp_figma "$cursor_mcp"
  fi

  echo ""
  read -r -p "Merge Figma MCP into $claude_mcp (Claude Code project MCP)? [Y/n] " a_claude
  if [[ "${a_claude:-y}" =~ ^[Yy]|^$ ]]; then
    merge_claude_mcp_figma "$claude_mcp"
  fi

  echo ""
  echo "Done."
  echo ""
  if [[ "$ds_file_url" == *"pending"* ]]; then
    echo "⚠  NEXT STEPS:"
    echo "   1. Create the Design System file '$ds_file_name' in Figma"
    echo "      inside the '$selected_project_name' project."
    echo "   2. Add the required pages: Cover, Foundations, Atoms, Molecules, Organisms"
    echo "   3. Publish it as a team library."
    echo "   4. Re-run this script to update the file reference."
  else
    echo "✓  Figma tool configured. Authenticate the MCP server through your"
    echo "   editor (Cursor or Claude Code) on first use."
  fi
}

main "$@"
