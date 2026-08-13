#!/usr/bin/env bash
# run.sh — run the test suite for the shell scripts in this repo.
#
# Usage:
#   .agents/tests/run.sh              # run every tests/test_*.sh
#   .agents/tests/run.sh hooks        # run the files whose name matches "hooks"
#
# Exit status is 0 when every test passes.
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FILTER="${1:-}"

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_RED="$(printf '\033[31m')"; C_GREEN="$(printf '\033[32m')"
  C_BOLD="$(printf '\033[1m')"; C_OFF="$(printf '\033[0m')"
else
  C_RED=""; C_GREEN=""; C_BOLD=""; C_OFF=""
fi

tally="$(mktemp "${TMPDIR:-/tmp}/byrde-tally.XXXXXX")"
export BYRDE_TEST_TALLY="$tally"

printf '%s══ Byrde Agents · tests ══%s\n\n' "$C_BOLD" "$C_OFF"

ran=0
for file in "$TESTS_DIR"/test_*.sh; do
  [ -f "$file" ] || continue
  if [ -n "$FILTER" ]; then
    case "$(basename "$file")" in *"$FILTER"*) ;; *) continue ;; esac
  fi
  ran=$((ran + 1))
  bash "$file" || true
done

if [ "$ran" -eq 0 ]; then
  printf 'no test files matched "%s"\n' "$FILTER" >&2
  rm -f "$tally"
  exit 1
fi

passed=0; failed=0; skipped=0
while read -r p f s; do
  passed=$((passed + p)); failed=$((failed + f)); skipped=$((skipped + s))
done <"$tally"
rm -f "$tally"

total=$((passed + failed + skipped))
if [ "$failed" -eq 0 ]; then
  printf '%s✓ %s tests: %s passed, %s skipped%s\n' "$C_GREEN" "$total" "$passed" "$skipped" "$C_OFF"
  exit 0
fi
printf '%s✗ %s tests: %s passed, %s FAILED, %s skipped%s\n' \
  "$C_RED" "$total" "$passed" "$failed" "$skipped" "$C_OFF"
exit 1
