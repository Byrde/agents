#!/usr/bin/env bash
# Bootstrap a host project with Byrde Agents.
#
# Copies rules and skills into the project's editor directories so the
# Claude and Cursor agents can pick them up, and turns ON Claude Code's
# built-in auto-memory (the default). Optional setup steps (GitHub tool
# skills, Figma tool skills, mempalace memory) are run separately as their
# own scripts. setup-memory.sh turns auto-memory OFF — mempalace replaces
# Claude's native memory — and turns it back ON when uninstalled.
#
# Run from the repository/project root you want to initialise.
# Writes:
#   - .cursor/rules/          — global AI rules for Cursor
#   - .claude/rules/          — global AI rules for Claude Code
#   - .cursor/skills/         — agent skills copied into Cursor dir
#   - .claude/skills/         — agent skills copied into Claude Code dir
#   - .claude/settings.json   — autoMemoryEnabled: true (Claude Code default)
#
# Does not modify $HOME.
#
# Usage:
#   cd /path/to/project && /path/to/init.sh              # install
#   cd /path/to/project && /path/to/init.sh uninstall    # remove what install wrote
#
# Requires: jq (only for the auto-memory step; rules/skills work without it)
# Compatible with Bash 3.2 (macOS): no mapfile/readarray.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENTS_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SKILLS_DIR="$AGENTS_ROOT/skills"
RULES_DIR="$AGENTS_ROOT/rules"

TOOL_VERSION="0.1.0"
PROG_NAME="$(basename "${BASH_SOURCE[0]}")"

# ─── Utilities ───────────────────────────────────────────────────────────────

die() {
  echo "error: $*" >&2
  exit 1
}

# Set Claude Code's built-in auto-memory flag in .claude/settings.json.
# Auto-memory is ON by default; init turns it on explicitly so the project
# state is unambiguous, and setup-memory turns it off (mempalace takes over).
# Best-effort: needs jq to merge safely. Warns and skips if jq is missing —
# the auto-memory default still applies, it just isn't written explicitly.
set_auto_memory() {
  local project_root="$1" value="$2"  # value: true | false
  local settings="$project_root/.claude/settings.json"
  if ! command -v jq >/dev/null 2>&1; then
    echo "  ⚠ jq not found — skipping autoMemoryEnabled=$value"
    echo "    (set \"autoMemoryEnabled\": $value in $settings manually if needed)"
    return 0
  fi
  mkdir -p "$(dirname "$settings")"
  local tmp
  tmp="$(mktemp)"
  if [[ -f "$settings" ]]; then
    jq --argjson v "$value" '.autoMemoryEnabled = $v' "$settings" >"$tmp" \
      || { echo "  ⚠ jq failed on $settings — leaving autoMemoryEnabled unchanged"; rm -f "$tmp"; return 0; }
  else
    jq -n --argjson v "$value" '{autoMemoryEnabled: $v}' >"$tmp"
  fi
  mv "$tmp" "$settings"
  echo "  ✓ autoMemoryEnabled=$value → .claude/settings.json"
}

# Remove the autoMemoryEnabled key from .claude/settings.json (uninstall),
# reverting Claude Code to its built-in default. Leaves any other settings
# intact, and removes the file only if it becomes an empty object.
del_auto_memory() {
  local project_root="$1"
  local settings="$project_root/.claude/settings.json"
  [[ -f "$settings" ]] || return 0
  command -v jq >/dev/null 2>&1 || { echo "  ⚠ jq not found — leaving $settings as-is"; return 0; }
  local tmp
  tmp="$(mktemp)"
  if jq 'del(.autoMemoryEnabled)' "$settings" >"$tmp" 2>/dev/null; then
    if [[ "$(jq -S 'keys' "$tmp")" == "[]" ]]; then
      rm -f "$tmp" "$settings"
      echo "  ✓ removed autoMemoryEnabled (and empty .claude/settings.json)"
    else
      mv "$tmp" "$settings"
      echo "  ✓ removed autoMemoryEnabled from .claude/settings.json"
    fi
  else
    rm -f "$tmp"
    echo "  ⚠ jq failed on $settings — leaving it unchanged"
  fi
}

print_intro() {
  local project_root="$1"
  local bar
  bar="$(printf '%*s' 68 '' | tr ' ' '=')"
  echo "$bar"
  echo "  $PROG_NAME · Byrde Agents  v$TOOL_VERSION"
  echo ""
  echo "  Bootstrap a project with Byrde Agents — installs rules and skills"
  echo "  into your editor directories so Claude Code and Cursor can pick"
  echo "  them up."
  echo ""
  printf '  %-16s %s\n' "Project Root" "$project_root"
  printf '  %-16s %s\n' "Agents Root" "$AGENTS_ROOT"
  printf '  %-16s %s\n' "Skills Source" "$SKILLS_DIR"
  printf '  %-16s %s\n' "Rules Source" "$RULES_DIR"
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
  echo "  Installed:"
  echo "    ✓ Rules   → .cursor/rules/  and  .claude/rules/"
  echo "    ✓ Skills  → .cursor/skills/ and  .claude/skills/"
  echo "    ✓ Claude Code auto-memory → on (.claude/settings.json)"
  echo ""
  echo "  Optional next steps:"
  echo "    • .agents/scripts/setup-github.sh   (GitHub tool skills)"
  echo "    • .agents/scripts/setup-figma.sh    (Figma tool skills)"
  echo "    • .agents/scripts/setup-memory.sh   (mempalace memory; turns auto-memory off)"
  echo "    • In your editor: run /create-readme to bootstrap the README"
  echo ""
  echo "  Verify with: .agents/scripts/doctor.sh"
  echo "  Undo with:   .agents/scripts/init.sh uninstall"
  echo "$bar"
}

# ─── Step 1: Install Rules ───────────────────────────────────────────────────

copy_rules() {
  local project_root="$1"

  echo "── Step 1/3: Install Rules ────────────────────────────────────────"
  echo ""

  if [[ ! -d "$RULES_DIR" ]]; then
    die "rules directory not found at $RULES_DIR"
  fi

  local cursor_rules="$project_root/.cursor/rules"
  local claude_rules="$project_root/.claude/rules"

  mkdir -p "$cursor_rules" "$claude_rules"

  local count=0
  for file in "$RULES_DIR"/*; do
    [[ -f "$file" ]] || continue

    local name
    name="$(basename "$file")"

    cp "$file" "$cursor_rules/$name"
    cp "$file" "$claude_rules/$name"

    printf '  %-24s → .cursor/rules/%s\n' "$name" "$name"
    printf '  %-24s → .claude/rules/%s\n' "" "$name"
    count=$((count + 1))
  done

  echo ""
  echo "  ✓ $count rule(s) installed to .cursor/rules/ and .claude/rules/"
  echo ""
}

# ─── Step 2: Install Skills ─────────────────────────────────────────────────

copy_skills() {
  local project_root="$1"

  echo "── Step 2/3: Install Skills ───────────────────────────────────────"
  echo ""

  if [[ ! -d "$SKILLS_DIR" ]]; then
    die "skills directory not found at $SKILLS_DIR"
  fi

  local cursor_skills="$project_root/.cursor/skills"
  local claude_skills="$project_root/.claude/skills"

  mkdir -p "$cursor_skills" "$claude_skills"

  # Copy the *contents* of skills/ into the dest dirs. Using a trailing "/."
  # (rather than "$SKILLS_DIR") keeps this idempotent: cp -R into an existing
  # directory would otherwise nest the source as .cursor/skills/skills/.
  cp -R "$SKILLS_DIR/." "$cursor_skills/"
  cp -R "$SKILLS_DIR/." "$claude_skills/"

  echo "  skills/ → .cursor/skills/"
  echo "  skills/ → .claude/skills/"
  echo ""
  echo "  ✓ Skills installed."
  echo ""
}

# ─── Step 3: Claude Code auto-memory (on by default) ─────────────────────────

enable_auto_memory() {
  local project_root="$1"

  echo "── Step 3/3: Claude Code auto-memory ──────────────────────────────"
  echo ""
  echo "  Turning ON Claude Code's built-in auto-memory (the default)."
  echo "  setup-memory.sh turns this off — mempalace replaces it — and back"
  echo "  on when uninstalled."
  echo ""
  set_auto_memory "$project_root" true
  echo ""
}

# ─── Uninstall ───────────────────────────────────────────────────────────────

# Remove the rules init copied: one dest per file in rules/, in both editor dirs.
remove_rules() {
  local project_root="$1"
  echo "── Removing rules ─────────────────────────────────────────────────"
  echo ""
  [[ -d "$RULES_DIR" ]] || { echo "  (no rules source — skipping)"; echo ""; return 0; }
  local file name count=0
  for file in "$RULES_DIR"/*; do
    [[ -f "$file" ]] || continue
    name="$(basename "$file")"
    rm -f "$project_root/.cursor/rules/$name" "$project_root/.claude/rules/$name"
    printf '  removed  %s\n' "$name"
    count=$((count + 1))
  done
  # Drop the rule dirs if init emptied them.
  rmdir "$project_root/.cursor/rules" "$project_root/.claude/rules" 2>/dev/null || true
  echo ""
  echo "  ✓ $count rule(s) removed from .cursor/rules/ and .claude/rules/"
  echo ""
}

# Remove the skills init copied: one dest per entry in skills/, in both editor
# dirs. Mirrors copy_skills (which copies the whole skills/ tree).
remove_skills() {
  local project_root="$1"
  echo "── Removing skills ────────────────────────────────────────────────"
  echo ""
  [[ -d "$SKILLS_DIR" ]] || { echo "  (no skills source — skipping)"; echo ""; return 0; }
  local entry name dest
  for entry in "$SKILLS_DIR"/*; do
    [[ -e "$entry" ]] || continue
    name="$(basename "$entry")"
    for dest in "$project_root/.cursor/skills" "$project_root/.claude/skills"; do
      rm -rf "${dest:?}/$name"
    done
    printf '  removed  %s\n' "$name"
  done
  rmdir "$project_root/.cursor/skills" "$project_root/.claude/skills" 2>/dev/null || true
  echo ""
  echo "  ✓ Skills removed from .cursor/skills/ and .claude/skills/"
  echo ""
}

uninstall() {
  local project_root="$1"
  local bar
  bar="$(printf '%*s' 68 '' | tr ' ' '=')"
  echo "$bar"
  echo "  $PROG_NAME · Uninstall  v$TOOL_VERSION"
  echo ""
  echo "  Removes the rules and skills init.sh copied into your editor dirs,"
  echo "  and the autoMemoryEnabled flag it wrote. Does NOT touch tool skills'"
  echo "  MCP/hooks config — run each setup-*.sh uninstall for those."
  echo ""
  printf '  %-16s %s\n' "Project Root" "$project_root"
  echo "$bar"
  echo ""

  remove_rules "$project_root"
  remove_skills "$project_root"

  echo "── Reverting auto-memory ──────────────────────────────────────────"
  echo ""
  del_auto_memory "$project_root"
  echo ""

  echo "$bar"
  echo "  Done. Rules, skills, and the auto-memory flag removed."
  echo "  Tool skills installed by setup-*.sh are untouched — uninstall those"
  echo "  with their own scripts (e.g. setup-memory.sh uninstall)."
  echo "$bar"
}

# ─── Main ────────────────────────────────────────────────────────────────────

main() {
  case "${1:-}" in
    -h | --help | help)
      echo "$PROG_NAME · Byrde Agents v$TOOL_VERSION"
      echo ""
      echo "Usage:"
      echo "  cd /your/project && $0              # install rules + skills, auto-memory on"
      echo "  cd /your/project && $0 uninstall    # remove what install wrote"
      echo ""
      echo "Install copies .agents/rules/ and .agents/skills/ into .cursor/ and"
      echo ".claude/, and sets autoMemoryEnabled: true in .claude/settings.json"
      echo "(Claude Code's built-in auto-memory; the default)."
      echo ""
      echo "Uninstall removes those copied rules/skills and the auto-memory flag."
      echo "It does not touch MCP/hooks config from the setup-*.sh scripts."
      exit 0
      ;;
    uninstall | remove)
      local project_root
      project_root="$(pwd)"
      uninstall "$project_root"
      exit 0
      ;;
  esac

  local project_root
  project_root="$(pwd)"

  print_intro "$project_root"

  copy_rules "$project_root"
  copy_skills "$project_root"
  enable_auto_memory "$project_root"

  print_summary
}

main "$@"
