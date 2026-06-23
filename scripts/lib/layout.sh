#!/usr/bin/env bash
# Byrde Agents — project layout resolver (mono-repo vs multi-repo).
#
# A single .agents checkout can serve one project or several. This helper
# classifies the run and decides WHERE per-project artefacts (rendered tool
# skills + the installed-tools manifest) are staged. The shared submodule holds
# the read-only inputs (templates, rules, practice skills); the per-project
# OUTPUTS must not collide when one .agents serves multiple repos.
#
# Two modes:
#
#   mono   — the golden path. .agents is a direct child of the project root
#            (a submodule at the repo root, or vendored there). You run setup
#            from that root. Rendered skills + manifest stage inside the
#            checkout: <.agents>/skills/ and <.agents>/.manifest.local.yml —
#            exactly the behaviour from before multi-repo support existed.
#
#   multi  — one .agents at a workspace root sits ABOVE several sibling repos.
#            You run setup from inside one of those nested repos. Rendered
#            skills + manifest stage in a per-repo home, <repo>/.byrde/, so each
#            repo keeps its own coordinates (GitHub repo, Figma file, palace)
#            and a second repo's setup never clobbers the first.
#
# In BOTH modes the editor mirrors (.claude/skills, .cursor/skills) and the
# project MCP config (.mcp.json) live under PROJECT_ROOT — that was always
# per-project and is unchanged.
#
# Source this AFTER SCRIPT_DIR and AGENTS_ROOT are set, then call
# resolve_layout. It sets/exports:
#   WORKSPACE_ROOT  PROJECT_ROOT  AGENTS_MODE  SKILLS_HOME  SKILLS_DIR
#   MANIFEST_FILE   (consumed by lib/manifest.sh — source layout FIRST)
#
# Compatible with Bash 3.2 (macOS): no associative arrays, no mapfile.

# Per-project rendered/vendored tool skills — each owned by a setup-*.sh script
# (rendered from a template or vendored from upstream), NOT submodule-tracked.
# Returns 0 for a tool skill, 1 for a shared practice skill (plan, architect,
# design, develop, test) that init.sh seeds. Keep in sync with .agents/.gitignore.
is_tool_skill() {
  case "$1" in
    github-projects | google-analytics | jira | \
      figma-design-system | figma-design-file | figma-use | memory)
      return 0 ;;
    *)
      return 1 ;;
  esac
}

# Fill SIBLING_REPOS with the immediate child dirs of WORKSPACE_ROOT that are
# INDEPENDENT git repos — they have their own .git and are NOT submodules of the
# workspace repo (declared in .gitmodules), nor the .agents checkout itself.
# Their presence means WORKSPACE_ROOT is a multi-repo *container*, not a single
# project: one shared .agents sitting above several sibling repositories.
detect_sibling_repos() {
  SIBLING_REPOS=()
  local gitmodules="$WORKSPACE_ROOT/.gitmodules"
  local d name
  for d in "$WORKSPACE_ROOT"/*/; do
    [[ -d "$d" ]] || continue          # no matches → glob stays literal → skip
    name="$(basename "$d")"
    [[ "$name" == ".agents" ]] && continue
    [[ -e "$d/.git" ]] || continue     # not its own git repo
    # Skip declared submodules of the workspace repo (a mono-repo may have some).
    if [[ -f "$gitmodules" ]] \
       && grep -qE "^[[:space:]]*path[[:space:]]*=[[:space:]]*${name}/?[[:space:]]*\$" "$gitmodules" 2>/dev/null; then
      continue
    fi
    SIBLING_REPOS+=("$name")
  done
}

# Classify the run and resolve where per-project artefacts are staged.
# Honours PROJECT_ROOT_OVERRIDE (tests) in place of the current directory.
# Sets: WORKSPACE_ROOT PROJECT_ROOT AGENTS_MODE SKILLS_HOME SKILLS_DIR
#       MANIFEST_FILE SIBLING_REPOS
#
# The mono/multi flavour is a DECLARED choice, not a guess: it comes from the
# `mode` field of the workspace map (see lib/workspace.sh) when present. Callers
# that need it before the map exists pass AGENTS_MODE_OVERRIDE (e.g. setup-*.sh
# after asking the user). Absent both, we fall back to a path heuristic — never
# a hard stop.
#
# Modes:
#   mono   single project, or a multi-repo workspace operated as one unit —
#          stage tool skills in the .agents checkout.
#   multi  running inside a specific repo nested under the workspace root —
#          stage tool skills in <repo>/.byrde/.
resolve_layout() {
  : "${AGENTS_ROOT:?resolve_layout: AGENTS_ROOT must be set before sourcing/calling}"

  WORKSPACE_ROOT="$(cd "$AGENTS_ROOT/.." && pwd)"
  PROJECT_ROOT="${PROJECT_ROOT_OVERRIDE:-$(pwd -P)}"
  # Snap to the enclosing git repo root so "run from anywhere in the repo"
  # behaves the same as running from its root. Skipped under the test override.
  if [[ -z "${PROJECT_ROOT_OVERRIDE:-}" ]]; then
    local _top
    if _top="$(git -C "$PROJECT_ROOT" rev-parse --show-toplevel 2>/dev/null)"; then
      PROJECT_ROOT="$_top"
    fi
  fi

  detect_sibling_repos

  # Resolve the flavour: explicit override > declared mode in the workspace map
  # > path heuristic (running inside a sibling repo ⇒ multi, else mono).
  local declared=""
  if [[ -z "${AGENTS_MODE_OVERRIDE:-}" ]]; then
    declared="$(workspace_declared_mode 2>/dev/null || true)"
  fi
  AGENTS_MODE="${AGENTS_MODE_OVERRIDE:-$declared}"
  if [[ -z "$AGENTS_MODE" ]]; then
    if [[ "$PROJECT_ROOT" == "$WORKSPACE_ROOT"/* ]]; then
      AGENTS_MODE="multi"
    else
      AGENTS_MODE="mono"
    fi
  fi

  if [[ "$AGENTS_MODE" == "multi" && "$PROJECT_ROOT" == "$WORKSPACE_ROOT"/* ]]; then
    SKILLS_HOME="$PROJECT_ROOT/.byrde"
  else
    SKILLS_HOME="$AGENTS_ROOT"
  fi

  SKILLS_DIR="$SKILLS_HOME/skills"
  MANIFEST_FILE="$SKILLS_HOME/.manifest.local.yml"
  export WORKSPACE_ROOT PROJECT_ROOT AGENTS_MODE SKILLS_HOME SKILLS_DIR MANIFEST_FILE
}

# Best-effort: echo the declared mode (mono|multi) from the workspace map, or
# nothing. Defined as a weak fallback so layout.sh works even when workspace.sh
# hasn't been sourced; lib/workspace.sh overrides this with the real reader.
if ! declare -f workspace_declared_mode >/dev/null 2>&1; then
  workspace_declared_mode() { return 0; }
fi

# Human-readable one-liner describing the resolved layout, for setup intros and
# the doctor report.
layout_describe() {
  case "${AGENTS_MODE:-}" in
    multi) echo "multi-repo — per-repo home at ${SKILLS_HOME/#$PROJECT_ROOT\//}/ (shared .agents at $AGENTS_ROOT)" ;;
    mono)  echo "mono-repo — staged in the .agents checkout ($SKILLS_HOME)" ;;
    *)     echo "unresolved (call resolve_layout first)" ;;
  esac
}

# In multi-repo mode the per-repo .byrde/ home holds rendered skills + the
# manifest: per-project artefacts, never committed (mirrors how the submodule
# gitignores its own staging in .agents/.gitignore). Add it to the repo's
# .gitignore idempotently. No-op in mono mode (the submodule already ignores
# its staging). Safe to call more than once.
ignore_skills_home() {
  [[ "${AGENTS_MODE:-}" == "multi" ]] || return 0
  local gi="$PROJECT_ROOT/.gitignore"
  local line=".byrde/"
  if [[ -f "$gi" ]] && grep -qxF "$line" "$gi" 2>/dev/null; then
    return 0
  fi
  printf '\n# Byrde Agents — per-project rendered skills + manifest (multi-repo).\n%s\n' \
    "$line" >>"$gi"
  echo "  gitignored $line in ${gi#"$PROJECT_ROOT"/}"
}
