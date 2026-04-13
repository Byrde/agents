#!/usr/bin/env bash
# Bootstrap a host project with Byrde Agents.
#
# Runs setup-memory.sh interactively, copies rules and skills into the
# project's editor directories, and launches the Claude CLI with the
# /create-readme workflow.
#
# Run from the repository/project root you want to initialise.
# Writes:
#   - .cursor/                   — agent skills copied into Cursor dir
#   - .claude/                   — agent skills copied into Claude Code dir
#   - .cursor/rules/global.mdc  — global AI rules for Cursor
#   - .claude/rules/global.md   — global AI rules for Claude Code
#   - (everything setup-memory.sh writes — see that script's header)
#
# Does not modify $HOME.
#
# Usage: cd /path/to/project && /path/to/init.sh
#
# Requires: claude (Claude Code CLI)
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
  echo "  Bootstrap a project with Byrde Agents."
  echo "  Sets up mempalace, installs rules and skills, and launches"
  echo "  the /create-readme workflow via the Claude CLI."
  echo ""
  printf '  %-16s %s\n' "Project Root" "$project_root"
  printf '  %-16s %s\n' "Agents Root" "$AGENTS_ROOT"
  printf '  %-16s %s\n' "Skills Source" "$SKILLS_DIR"
  printf '  %-16s %s\n' "Rules Source" "$RULES_DIR"
  echo "$bar"
  echo ""
}

# ─── Step 1: Setup Memory ───────────────────────────────────────────────────

run_setup_memory() {
  local setup_memory="$SCRIPT_DIR/setup-memory.sh"
  if [[ ! -x "$setup_memory" ]]; then
    die "setup-memory.sh not found or not executable at $setup_memory"
  fi

  echo "── Step 1/4: Mempalace Setup ──────────────────────────────────────"
  echo ""
  "$setup_memory"
  echo ""
  echo "  ✓ Mempalace setup complete."
  echo ""
}

# ─── Step 2: Install Rules ───────────────────────────────────────────────────

copy_rules() {
  local project_root="$1"

  echo "── Step 2/4: Install Rules ────────────────────────────────────────"
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

# ─── Step 3: Install Skills ─────────────────────────────────────────────────

copy_skills() {
  local project_root="$1"

  echo "── Step 3/4: Install Skills ───────────────────────────────────────"
  echo ""

  if [[ ! -d "$SKILLS_DIR" ]]; then
    die "skills directory not found at $SKILLS_DIR"
  fi

  mkdir -p "$project_root/.cursor" "$project_root/.claude"

  cp -R "$SKILLS_DIR"/* "$project_root/.cursor/"
  cp -R "$SKILLS_DIR"/* "$project_root/.claude/"

  echo "  skills/ → .cursor/"
  echo "  skills/ → .claude/"
  echo ""
  echo "  ✓ Skills installed."
  echo ""
}

# ─── Step 4: Launch Claude CLI ───────────────────────────────────────────────

launch_claude() {
  echo "── Step 4/4: Launch Claude CLI ────────────────────────────────────"
  echo ""
  echo "  Launching Claude Code with /create-readme workflow..."
  echo ""

  require_cmd claude
  exec claude "/create-readme"
}

# ─── Main ────────────────────────────────────────────────────────────────────

main() {
  local project_root
  project_root="$(pwd)"

  print_intro "$project_root"

  run_setup_memory
  copy_rules "$project_root"
  copy_skills "$project_root"
  launch_claude
}

main "$@"
