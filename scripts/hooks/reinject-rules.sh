#!/usr/bin/env bash
# reinject-rules.sh — re-assert the project rules every Nth user message.
#
# The rules load once, at the start of a session. Nothing re-asserts them, so as a
# session grows they lose to the most recent tool result. Compliance decays without
# anyone noticing.
#
# This runs on UserPromptSubmit and prints the rules back into context every Nth
# message. stdout from this event is added as context, so printing IS the injection.
#
# Cadence: BYRDE_RULES_REINJECT_EVERY (default 10). Set 0 to disable.
# State: one counter file per session under the project's .claude/ directory.
set -uo pipefail

every="${BYRDE_RULES_REINJECT_EVERY:-10}"
[ "$every" = "0" ] && exit 0

payload="$(cat 2>/dev/null || true)"
session="$(printf '%s' "$payload" | sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
[ -n "$session" ] || session="default"

root="${CLAUDE_PROJECT_DIR:-$PWD}"
rules_dir="$root/.claude/rules"
[ -d "$rules_dir" ] || exit 0

state_dir="$root/.claude/.byrde"
mkdir -p "$state_dir" 2>/dev/null || exit 0
counter="$state_dir/rules-reinject.$session"

n=0
[ -f "$counter" ] && n="$(cat "$counter" 2>/dev/null || echo 0)"
case "$n" in *[!0-9]*) n=0 ;; esac
n=$((n + 1))
printf '%s' "$n" >"$counter" 2>/dev/null || true

# Fire on the first message and every Nth after it.
if [ "$n" -ne 1 ] && [ $((n % every)) -ne 0 ]; then exit 0; fi

printf '<project-rules-reinjected message="%s">\n' "$n"
printf 'These rules are binding and were last shown %s messages ago. Re-read them.\n\n' "$every"
# global.md leads: it carries the re-grounding checks, and the first thing read
# after a long stretch should be the one that asks what drifted.
seen=""
for f in "$rules_dir/global.md" "$rules_dir"/*.md; do
  [ -f "$f" ] || continue
  case " $seen " in *" $f "*) continue ;; esac
  seen="${seen:-} $f"
  printf '\n===== %s =====\n' "$(basename "$f")"
  cat "$f"
done
printf '\n</project-rules-reinjected>\n'
