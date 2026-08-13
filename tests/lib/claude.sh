#!/usr/bin/env bash
# claude.sh — drive a real, headless Claude Code session and read back what the
# hooks did.
#
# The tests that use this library prove behavior end to end: the CLI runs, the
# hook runs inside it, and the hook output lands in the model's context. They
# call the API, so they cost money and need the `claude` CLI to be logged in.
# They always run. `require_live` skips a test only when the machine cannot run
# it at all.
#
# Observation points, in order of strength:
#   1. hook_output   — what the hook printed, as the CLI recorded it.
#   2. result_text   — what the model answered. This is the only evidence that
#                      the hook output reached the context window.
#   3. counter/state — what the hook wrote to disk.

# Model for live turns. Haiku keeps a turn near one cent.
LIVE_MODEL="${BYRDE_TEST_MODEL:-claude-haiku-4-5-20251001}"
# Ceiling per turn, in dollars. The CLI stops the turn if it goes over.
LIVE_BUDGET_USD="${BYRDE_TEST_BUDGET_USD:-0.50}"

# require_live — skip the calling test when this machine cannot run a session.
require_live() {
  command -v claude >/dev/null 2>&1 \
    || skip "the claude CLI is not on PATH"
  command -v jq >/dev/null 2>&1 \
    || skip "jq is not on PATH"
}

# new_session_id — a lowercase UUID the CLI accepts for --session-id.
new_session_id() {
  if command -v uuidgen >/dev/null 2>&1; then
    uuidgen | tr 'A-Z' 'a-z'
  else
    od -x /dev/urandom | head -1 | awk '{OFS="-"; print $2$3,$4,$5,$6,$7$8$9}'
  fi
}

# live_project <dir> — create a project that looks like an initialised one:
# a .claude/rules/ directory with a marker in it. The caller adds the hooks.
live_project() {
  local root="$1"
  mkdir -p "$root/.claude/rules"
  cat >"$root/.claude/rules/global.md" <<'EOF'
# Working in this project

RULE_FILE_MARKER — this line lives in a rule FILE.
EOF
}

# write_hook_settings <dir> <event> <command> — wire one command hook into the
# project's .claude/settings.json, replacing whatever was there.
write_hook_settings() {
  local root="$1" event="$2" cmd="$3"
  mkdir -p "$root/.claude"
  jq -n --arg ev "$event" --arg cmd "$cmd" \
    '{hooks: {($ev): [{matcher: "*", hooks: [{type: "command", command: $cmd}]}]}}' \
    >"$root/.claude/settings.json"
}

# claude_turn <project_dir> <transcript_out> <prompt> [extra CLI args...]
#
# Run one non-interactive turn in <project_dir>. Writes the stream-json
# transcript to <transcript_out> and the CLI's own stderr to
# <transcript_out>.err. Returns the CLI exit status.
#
# --setting-sources project keeps the sandbox honest: the run reads the
# sandbox's .claude/settings.json and ignores the operator's user settings, so
# a hook configured at ~/.claude cannot make a test pass.
claude_turn() {
  local proj="$1" out="$2" prompt="$3"
  shift 3
  ( cd "$proj" && claude -p "$prompt" \
      --model "$LIVE_MODEL" \
      --output-format stream-json \
      --include-hook-events \
      --verbose \
      --setting-sources project \
      --max-budget-usd "$LIVE_BUDGET_USD" \
      "$@" </dev/null ) >"$out" 2>"$out.err"
}

# assert_turn_ok <transcript> <message> — the turn ran and produced a result.
assert_turn_ok() {
  local out="$1" msg="$2"
  assert_file "$out" "$msg — no transcript was written"
  if ! grep -q '"type":"result"' "$out"; then
    fail "$msg — the turn produced no result event
        stderr: $(head -c 300 "$out.err" 2>/dev/null)
        stdout: $(head -c 300 "$out")"
  fi
}

# ─── Reading the transcript ──────────────────────────────────────────────────
#
# A command hook shows up as two system events: hook_started, then
# hook_response carrying .output, .stdout, .stderr, .exit_code and .outcome.

# hook_output <transcript> <event> — everything the hooks for <event> printed.
hook_output() {
  jq -r --arg ev "$2" \
    'select(.subtype == "hook_response" and .hook_event == $ev) | .output // ""' "$1"
}

# hook_stderr <transcript> <event> — anything the hooks for <event> wrote to stderr.
hook_stderr() {
  jq -r --arg ev "$2" \
    'select(.subtype == "hook_response" and .hook_event == $ev) | .stderr // ""' "$1"
}

# hook_exit_codes <transcript> <event> — one exit status per hook that ran.
hook_exit_codes() {
  jq -r --arg ev "$2" \
    'select(.subtype == "hook_response" and .hook_event == $ev) | .exit_code' "$1"
}

# hook_ran <transcript> <event> — "yes" when a hook for <event> ran, else "no".
hook_ran() {
  local n
  n="$(jq -s --arg ev "$2" \
    '[.[] | select(.subtype == "hook_response" and .hook_event == $ev)] | length' "$1")"
  [ "$n" -gt 0 ] && echo "yes" || echo "no"
}

# result_text <transcript> — the model's final answer for the turn.
result_text() {
  jq -r 'select(.type == "result") | .result // ""' "$1"
}

# permission_denials <transcript> — how many tool calls were denied.
permission_denials() {
  jq -r 'select(.type == "result") | (.permission_denials | length)' "$1"
}

# tool_names <transcript> — every tool the model actually invoked.
tool_names() {
  jq -r 'select(.type == "assistant") | .message.content[]?
         | select(.type == "tool_use") | .name' "$1"
}
