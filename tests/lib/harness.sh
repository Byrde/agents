#!/usr/bin/env bash
# harness.sh — a small test harness for the shell scripts in this repo.
#
# No dependencies beyond bash 3.2 and coreutils. A test file sources this
# library, defines one or more `test_*` functions, and calls `run_tests` at the
# end. Each test runs in a subshell with its own temporary directory, so a test
# cannot leak state into the next one.
#
# An assertion that fails prints the reason and ends that test. The rest of the
# file still runs.
#
# Usage:
#   . "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
#   test_something() { assert_eq "a" "a" "a equals a"; }
#   run_tests
set -uo pipefail

HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_DIR="$(cd "$HARNESS_DIR/.." && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
export TESTS_DIR REPO_ROOT

# ─── Output ──────────────────────────────────────────────────────────────────

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_RED="$(printf '\033[31m')"; C_GREEN="$(printf '\033[32m')"
  C_YELLOW="$(printf '\033[33m')"; C_DIM="$(printf '\033[2m')"
  C_OFF="$(printf '\033[0m')"
else
  C_RED=""; C_GREEN=""; C_YELLOW=""; C_DIM=""; C_OFF=""
fi

_passed=0
_failed=0
_skipped=0

# ─── Assertions ──────────────────────────────────────────────────────────────
#
# Each assertion runs inside the test subshell. A failure prints the reason and
# exits the subshell with status 1, which the runner records as a failed test.

_abort() {
  printf '%s      %s%s\n' "$C_RED" "$1" "$C_OFF" >&2
  shift
  local line
  for line in "$@"; do printf '        %s\n' "$line" >&2; done
  exit 1
}

# assert_eq <expected> <actual> <message>
assert_eq() {
  [ "$1" = "$2" ] && return 0
  _abort "$3" "expected: $1" "actual:   $2"
}

# assert_contains <haystack> <needle> <message>
assert_contains() {
  case "$1" in *"$2"*) return 0 ;; esac
  _abort "$3" "expected to contain: $2" "actual: $(printf '%s' "$1" | head -c 400)"
}

# assert_not_contains <haystack> <needle> <message>
assert_not_contains() {
  case "$1" in *"$2"*) ;; *) return 0 ;; esac
  _abort "$3" "expected NOT to contain: $2" "actual: $(printf '%s' "$1" | head -c 400)"
}

# assert_empty <value> <message>
assert_empty() {
  [ -z "$1" ] && return 0
  _abort "$2" "expected empty output" "actual: $(printf '%s' "$1" | head -c 400)"
}

# assert_status <expected> <actual> <message>
assert_status() {
  [ "$1" = "$2" ] && return 0
  _abort "$3" "expected exit status: $1" "actual exit status:   $2"
}

# assert_file <path> <message>
assert_file() {
  [ -f "$1" ] && return 0
  _abort "$2" "expected a file at: $1"
}

# assert_no_file <path> <message>
assert_no_file() {
  [ -f "$1" ] || return 0
  _abort "$2" "expected no file at: $1" "content: $(head -c 400 "$1")"
}

# assert_json <file> <jq-filter> <expected> <message>
assert_json() {
  local actual
  actual="$(jq -r "$2" "$1" 2>&1)"
  [ "$actual" = "$3" ] && return 0
  _abort "$4" "filter:   $2" "expected: $3" "actual:   $actual" "file:     $(cat "$1")"
}

# fail <message>
fail() { _abort "$1"; }

# skip <reason> — mark the running test as skipped and stop it.
skip() {
  printf '%s      skipped: %s%s\n' "$C_YELLOW" "$1" "$C_OFF"
  exit 99
}

# ─── Fixtures ────────────────────────────────────────────────────────────────

# make_project <dir> — build a minimal project that looks like an installed one:
# a .claude/rules directory with two rules and one Cursor-only .mdc twin.
make_project() {
  local root="$1"
  mkdir -p "$root/.claude/rules"
  cat >"$root/.claude/rules/global.md" <<'EOF'
# Working in this project
GLOBAL_RULE_MARKER
EOF
  cat >"$root/.claude/rules/development.md" <<'EOF'
# Architectural Standard Operating Procedure
DEVELOPMENT_RULE_MARKER
EOF
  cat >"$root/.claude/rules/development.mdc" <<'EOF'
CURSOR_ONLY_MARKER
EOF
}

# ─── Runner ──────────────────────────────────────────────────────────────────

# run_tests — run every `test_*` function defined by the caller, in name order.
run_tests() {
  local file_name
  file_name="$(basename "${BASH_SOURCE[1]:-tests}")"
  printf '%s%s%s\n' "$C_DIM" "$file_name" "$C_OFF"

  local names name status sandbox
  names="$(declare -F | sed -n 's/^declare -f \(test_[A-Za-z0-9_]*\)$/\1/p' | sort)"

  for name in $names; do
    sandbox="$(mktemp -d "${TMPDIR:-/tmp}/byrde-test.XXXXXX")"
    ( SANDBOX="$sandbox"; export SANDBOX; cd "$sandbox" && "$name" )
    status=$?
    rm -rf "$sandbox"
    case "$status" in
      0)  _passed=$((_passed + 1)); printf '  %s✓%s %s\n' "$C_GREEN" "$C_OFF" "${name#test_}" ;;
      99) _skipped=$((_skipped + 1)); printf '  %s-%s %s\n' "$C_YELLOW" "$C_OFF" "${name#test_}" ;;
      *)  _failed=$((_failed + 1)); printf '  %s✗%s %s\n' "$C_RED" "$C_OFF" "${name#test_}" ;;
    esac
  done

  printf '  %s%s passed, %s failed, %s skipped%s\n\n' \
    "$C_DIM" "$_passed" "$_failed" "$_skipped" "$C_OFF"

  # The runner sums these across files.
  if [ -n "${BYRDE_TEST_TALLY:-}" ]; then
    printf '%s %s %s\n' "$_passed" "$_failed" "$_skipped" >>"$BYRDE_TEST_TALLY"
  fi

  [ "$_failed" -eq 0 ]
}
