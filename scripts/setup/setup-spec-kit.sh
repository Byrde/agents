#!/usr/bin/env bash
# Install GitHub Spec Kit for the harnesses init.sh chose.
#
# Spec Kit holds the phases of feature-sized work: specify, plan, tasks,
# implement, converge. The `global` rule tells the agent when to run them, so
# the user never types one. A fix needs none of this.
#
# What this script does, in the project root:
#   1. `specify init`, once. A project that already has .specify/ keeps it.
#   2. One Spec Kit integration per place the harnesses read skills from:
#        claude  → .claude/skills/speckit-*   (Claude Code)
#        codex   → .agents/skills/speckit-*   (the shared folder: Cursor, Codex,
#                  Copilot, Antigravity and OpenCode all read it)
#      A harness init.sh dropped loses its integration.
#   3. Two presets. `lean`, bundled with Spec Kit, replaces the five core
#      prompts with short ones. `byrde`, from spec-kit/preset/, replaces the
#      specify prompt: it names the feature directory itself and writes user
#      stories that a work item can carry.
#   4. A constitution that points at .agents/rules/, written only while the
#      file is still the empty template.
#
#   5. An ignore block in .gitignore for the state that differs from one
#      machine to the next: which integrations and presets are installed.
#
# specs/ and the rest of .specify/ are the project's record. Commit them. The
# skill files and the ignored state are generated, and this script restores
# them on a fresh clone.
#
# The Spec Kit CLI runs through `uvx`, pinned to SPEC_KIT_VERSION, from the
# GitHub repository. The PyPI package of the same name is not GitHub's. Set
# BYRDE_SPECIFY to a `specify` binary to use that one.
#
# Usage:
#   cd /your/project && .agents/scripts/setup/setup-spec-kit.sh             # install or refresh
#   cd /your/project && .agents/scripts/setup/setup-spec-kit.sh uninstall   # remove the skills
#
# Requires: jq, and uv (https://docs.astral.sh/uv/) or a `specify` binary.
# Bash 3.2 (macOS) compatible.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENTS_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../lib/layout.sh
. "$SCRIPT_DIR/../lib/layout.sh"
resolve_layout
# shellcheck source=../lib/manifest.sh
. "$SCRIPT_DIR/../lib/manifest.sh"
# shellcheck source=../lib/harness.sh
. "$SCRIPT_DIR/../lib/harness.sh"

SPEC_KIT_VERSION="v1.4.3"
SPEC_KIT_SOURCE="git+https://github.com/github/spec-kit.git@$SPEC_KIT_VERSION"
PRESET_DIR="$AGENTS_ROOT/spec-kit/preset"
CONSTITUTION_SRC="$AGENTS_ROOT/spec-kit/constitution.md"
# The integrations this script owns. It never touches another one.
OWNED_INTEGRATIONS="codex claude"
PROG_NAME="$(basename "${BASH_SOURCE[0]}")"

die() {
  echo "error: $*" >&2
  exit 1
}

# ─── The Spec Kit CLI ────────────────────────────────────────────────────────

SK=()
resolve_cli() {
  if [[ -n "${BYRDE_SPECIFY:-}" ]]; then
    # An explicit choice. No fallback when it is wrong.
    command -v "$BYRDE_SPECIFY" >/dev/null 2>&1 || return 1
    SK=("$BYRDE_SPECIFY")
  elif command -v uvx >/dev/null 2>&1; then
    SK=(uvx --from "$SPEC_KIT_SOURCE" specify)
  elif command -v specify >/dev/null 2>&1; then
    SK=(specify)
  else
    return 1
  fi
}

# Run the CLI quietly. On a failure, show what it printed.
sk() {
  local out
  if ! out="$("${SK[@]}" "$@" </dev/null 2>&1)"; then
    printf '%s\n' "$out" | tail -n 15 >&2
    return 1
  fi
}

# ─── What to install ─────────────────────────────────────────────────────────

# The integrations the selected harnesses need. The default one comes last.
wanted_integrations() {
  local h shared=0 out=""
  for h in $(harness_selected); do
    [[ "$h" == "claude" ]] || shared=1
  done
  # OpenCode has its own installer, and reads .agents/skills/ too.
  [[ -d "$PROJECT_ROOT/.opencode" ]] && shared=1
  [[ "$shared" -eq 1 ]] && out="codex"
  harness_has claude && out="$out claude"
  echo "${out# }"
}

installed_integrations() {
  [[ -f "$PROJECT_ROOT/.specify/integration.json" ]] || return 0
  jq -r '(.installed_integrations // []) | join(" ")' "$PROJECT_ROOT/.specify/integration.json" 2>/dev/null || true
}

in_list() {
  case " $1 " in *" $2 "*) return 0 ;; esac
  return 1
}

# ─── Install ─────────────────────────────────────────────────────────────────

install_integrations() {
  local want="$1" have key
  if [[ ! -f "$PROJECT_ROOT/.specify/integration.json" ]]; then
    sk init --here --force --non-interactive --ignore-agent-tools --integration "${want%% *}" \
      || die "specify init failed"
    echo "  ✓ specify init → .specify/"
  fi
  have="$(installed_integrations)"
  for key in $want; do
    in_list "$have" "$key" && continue
    sk integration install "$key" || die "could not install the $key integration"
  done
}

install_presets() {
  local listed
  listed="$("${SK[@]}" preset list </dev/null 2>/dev/null || true)"
  case "$listed" in
    *"(lean)"*) ;;
    *) sk preset add lean || die "could not add the lean preset" ;;
  esac
  # Spec Kit copies a preset. Add ours again so a newer checkout takes effect.
  case "$listed" in
    *"(byrde)"*) sk preset remove byrde || die "could not replace the byrde preset" ;;
  esac
  sk preset add --dev "$PRESET_DIR" --priority 5 || die "could not add the byrde preset"
  echo "  ✓ presets: lean, byrde"
}

# Write the skill files of each wanted integration, with the presets applied.
#
# Two facts about the CLI, v1.4.3, set the order:
#   - `upgrade` restores the files a fresh clone does not have. It needs
#     --force, because Spec Kit counts a skill that a preset rewrote as edited
#     by hand, and refuses. The skill files are generated: an edit to one does
#     not last.
#   - A preset reaches the skills of the default integration only. So each
#     integration becomes the default in turn. The last one stays the default.
write_skills() {
  local key
  for key in $1; do
    sk integration upgrade "$key" --force || die "could not write the $key skills"
  done
  for key in $1; do
    sk integration use "$key" || die "could not apply the presets to $key"
    echo "  ✓ skills: $key"
  done
}

remove_dropped_integrations() {
  local want="$1" have key
  have="$(installed_integrations)"
  for key in $OWNED_INTEGRATIONS; do
    in_list "$want" "$key" && continue
    in_list "$have" "$key" || continue
    sk integration uninstall "$key" || die "could not remove the $key integration"
    echo "  ✓ removed integration: $key (its harness is no longer selected)"
  done
}

# Which integrations and presets a checkout has follows the harnesses its
# developer chose, and each state file carries a timestamp. Committed, they
# would change on every run and differ between two developers. The block goes
# in the project's .gitignore: .specify/.gitignore is a file the CLI tracks by
# hash, and an edit there makes `specify integration status` warn for good.
GI_START="# --- byrde-agents spec-kit ---"
GI_END="# --- end byrde-agents spec-kit ---"
ignore_machine_state() {
  local gi="$PROJECT_ROOT/.gitignore"
  grep -qxF "$GI_START" "$gi" 2>/dev/null && return 0
  {
    echo ""
    echo "$GI_START"
    echo "# Per-machine Spec Kit state. setup-spec-kit.sh rebuilds it."
    echo ".specify/integration.json"
    echo ".specify/init-options.json"
    echo ".specify/integrations/"
    echo ".specify/presets/"
    echo "$GI_END"
  } >>"$gi"
}

write_constitution() {
  local live="$PROJECT_ROOT/.specify/memory/constitution.md"
  local template="$PROJECT_ROOT/.specify/templates/constitution-template.md"
  [[ -f "$live" && -f "$template" ]] || return 0
  cmp -s "$live" "$template" || return 0
  cp "$CONSTITUTION_SRC" "$live"
  echo "  ✓ constitution → points at .agents/rules/"
}

install() {
  local optional="$1" want
  command -v jq >/dev/null 2>&1 || die "missing required command: jq"
  if ! resolve_cli; then
    echo "  – Spec Kit not installed: found no Spec Kit CLI."
    echo "    Install uv (https://docs.astral.sh/uv/), or set BYRDE_SPECIFY to a specify"
    echo "    binary. Then run .agents/scripts/setup/$PROG_NAME"
    [[ "$optional" -eq 1 ]] && return 0
    return 1
  fi
  want="$(wanted_integrations)"
  [[ -n "$want" ]] || die "no harness is selected — run init.sh first"

  cd "$PROJECT_ROOT"
  install_integrations "$want"
  install_presets
  write_skills "$want"
  remove_dropped_integrations "$want"
  write_constitution
  ignore_machine_state
  manifest_add spec-kit
  echo "  ✓ Spec Kit $SPEC_KIT_VERSION. Commit .specify/ and specs/."
}

# ─── Uninstall ───────────────────────────────────────────────────────────────

uninstall() {
  local have key
  cd "$PROJECT_ROOT"
  have="$(installed_integrations)"
  if resolve_cli; then
    for key in $OWNED_INTEGRATIONS; do
      in_list "$have" "$key" || continue
      sk integration uninstall "$key" || echo "  ⚠ specify could not remove the $key integration"
    done
  fi
  # Whatever the CLI left, or all of it when there is no CLI.
  rm -rf "$PROJECT_ROOT"/.claude/skills/speckit-* "$PROJECT_ROOT"/.agents/skills/speckit-*
  manifest_remove spec-kit
  echo "  ✓ removed the Spec Kit skills"
  echo "    .specify/ and specs/ stay: they are the project's record. Delete them yourself."
}

# ─── Main ────────────────────────────────────────────────────────────────────

main() {
  local optional=0
  case "${1:-}" in
    -h | --help | help)
      echo "$PROG_NAME · Byrde Agents"
      echo ""
      echo "Installs GitHub Spec Kit $SPEC_KIT_VERSION for the harnesses init.sh chose,"
      echo "with the lean preset and the byrde preset."
      echo ""
      echo "Usage:"
      echo "  cd /your/project && $0              # install or refresh"
      echo "  cd /your/project && $0 uninstall    # remove the skills; .specify/ and specs/ stay"
      echo ""
      echo "Environment:"
      echo "  BYRDE_SPECIFY   Path of a specify binary to use in place of uvx."
      exit 0
      ;;
    uninstall | remove)
      uninstall
      exit 0
      ;;
    --optional) optional=1 ;;
  esac
  install "$optional"
}

main "$@"
