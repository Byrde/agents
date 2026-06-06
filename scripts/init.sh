#!/usr/bin/env bash
# Bootstrap a host project with Byrde Agents.
#
# Copies rules and skills into the project's editor directories so the
# Claude and Cursor agents can pick them up. Optional setup steps
# (GitHub tool skills, Figma tool skills) are run separately as their
# own scripts.
#
# Run from the repository/project root you want to initialise.
# Writes:
#   - .cursor/rules/   — global AI rules for Cursor
#   - .claude/rules/   — global AI rules for Claude Code
#   - .cursor/skills/  — agent skills copied into Cursor dir
#   - .claude/skills/  — agent skills copied into Claude Code dir
#
# Does not modify $HOME.
#
# Usage: cd /path/to/project && /path/to/init.sh
#
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
  echo ""
  echo "  Optional next steps:"
  echo "    • .agents/scripts/setup-github.sh   (GitHub tool skills)"
  echo "    • .agents/scripts/setup-figma.sh    (Figma tool skills)"
  echo "    • In your editor: run /create-readme to bootstrap the README"
  echo ""
  echo "  Verify with: .agents/scripts/doctor.sh"
  echo "$bar"
}

# ─── Step 1: Install Rules ───────────────────────────────────────────────────

copy_rules() {
  local project_root="$1"

  echo "── Step 1/2: Install Rules ────────────────────────────────────────"
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

  echo "── Step 2/2: Install Skills ───────────────────────────────────────"
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

# ─── Main ────────────────────────────────────────────────────────────────────

main() {
  local project_root
  project_root="$(pwd)"

  print_intro "$project_root"

  copy_rules "$project_root"
  copy_skills "$project_root"

  print_summary
}

main "$@"
