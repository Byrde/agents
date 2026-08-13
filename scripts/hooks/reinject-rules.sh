#!/usr/bin/env bash
# reinject-rules.sh — re-assert the project rules during a long agentic loop.
#
# The rules load once, at the start of a session. Nothing re-asserts them, so as
# a session grows they lose to the most recent tool result. Compliance decays
# without anyone noticing.
#
# A user message is the wrong trigger. The model can work for many minutes, and
# dozens of tool calls, between two of them — and that tool output is what
# buries the rules. So this runs on PostToolUse and re-injects every Nth tool
# call. The stream that buries the rules is the one that brings them back.
#
# PostToolUse ignores stdout: the model only reads
# hookSpecificOutput.additionalContext, so this hook answers with JSON.
# UserPromptSubmit is the opposite — there, stdout IS the injection. The hook
# handles both, so an install still wired the old way keeps working.
#
# Payload: global.md in full, plus a pointer to the other rule files. Short
# enough to repeat often, and repetition is what beats decay.
#
# Cadence: BYRDE_RULES_REINJECT_EVERY (default 12 tool calls). Set 0 to disable.
# State: one counter file per session under the project's .claude/ directory.
set -uo pipefail

every="${BYRDE_RULES_REINJECT_EVERY:-12}"
# A malformed cadence must not turn into an arithmetic error on every tool call.
case "$every" in '' | *[!0-9]*) every=12 ;; esac
[ "$every" = "0" ] && exit 0

payload="$(cat 2>/dev/null || true)"

# A PostToolUse payload carries the whole tool result, so read the fields with
# jq. The sed fallback covers a machine without jq.
if command -v jq >/dev/null 2>&1; then
  session="$(printf '%s' "$payload" | jq -r '.session_id // empty' 2>/dev/null)"
  event="$(printf '%s' "$payload" | jq -r '.hook_event_name // empty' 2>/dev/null)"
else
  session="$(printf '%s' "$payload" | sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
  event="$(printf '%s' "$payload" | sed -n 's/.*"hook_event_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
fi
[ -n "$session" ] || session="default"
[ -n "$event" ] || event="PostToolUse"

root="${CLAUDE_PROJECT_DIR:-$PWD}"
rules_dir="$root/.claude/rules"
[ -d "$rules_dir" ] || exit 0

# global.md leads: it carries the re-grounding checks, and the first thing read
# after a long stretch should be the one that asks what drifted.
lead="$rules_dir/global.md"
if [ ! -f "$lead" ]; then
  lead=""
  for f in "$rules_dir"/*.md; do
    [ -f "$f" ] && { lead="$f"; break; }
  done
fi
[ -n "$lead" ] || exit 0

state_dir="$root/.claude/.byrde"
mkdir -p "$state_dir" 2>/dev/null || exit 0
counter="$state_dir/rules-reinject.$session"

n=0
[ -f "$counter" ] && n="$(cat "$counter" 2>/dev/null || echo 0)"
case "$n" in *[!0-9]*) n=0 ;; esac
n=$((n + 1))
printf '%s' "$n" >"$counter" 2>/dev/null || true

# Fire every Nth tool call. Nothing fires at the start of a session: the rules
# are already in context there, and re-printing them buys nothing.
[ $((n % every)) -eq 0 ] || exit 0

# The other rule files, named but not printed. The model reads one when its next
# step touches that ground.
others=""
for f in "$rules_dir"/*.md; do
  [ -f "$f" ] || continue
  [ "$f" = "$lead" ] && continue
  others="${others:+$others, }$(basename "$f")"
done

build_context() {
  printf '<project-rules-reinjected after-tool-calls="%s">\n' "$n"
  printf 'These rules are binding. Tool output has pushed them out of view. Read them again before your next step.\n\n'
  cat "$lead"
  if [ -n "$others" ]; then
    printf '\nThe other rules are in .claude/rules/: %s.\n' "$others"
    printf 'Read one when your next step touches what it covers.\n'
  fi
  printf '</project-rules-reinjected>\n'
}

context="$(build_context)"

# UserPromptSubmit reads stdout as context. Every other event ignores stdout and
# reads additionalContext, which has to be JSON.
if [ "$event" = "UserPromptSubmit" ]; then
  printf '%s\n' "$context"
  exit 0
fi

# Without jq there is no safe way to escape the rules into JSON. Stay silent
# rather than hand the session a broken hook response.
command -v jq >/dev/null 2>&1 || exit 0
jq -n --arg ev "$event" --arg ctx "$context" \
  '{hookSpecificOutput: {hookEventName: $ev, additionalContext: $ctx}}'
