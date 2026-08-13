#!/usr/bin/env bash
# test_hook_wiring.sh — the wiring a live session depends on, checked for free.
#
# These tests start no session and cost nothing. They guard the ways a hook dies
# without a sound: the settings point at a path that no longer exists, the hook
# answers the CLI in a form the CLI ignores, or the cadence drifts.
#
# The end-to-end proof lives in test_hooks_live.sh.
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/harness.sh"

INIT="$REPO_ROOT/scripts/init.sh"
HOOK="$REPO_ROOT/scripts/hooks/reinject-rules.sh"

# Source init.sh for its helpers without running the installer.
load_init() {
  # shellcheck source=/dev/null
  . "$INIT"
  set +e   # init.sh sets -e; the harness needs to see failures, not die on them.
}

# A PostToolUse payload shaped like the one Claude Code sends: the whole tool
# result rides along, quotes and all.
tool_payload() {
  jq -nc --arg sid "${1:-11111111-2222-3333-4444-555555555555}" --arg cwd "$SANDBOX" \
    '{session_id: $sid, transcript_path: "/tmp/t.jsonl", cwd: $cwd,
      hook_event_name: "PostToolUse", tool_name: "Read",
      tool_input: {file_path: "a.txt"},
      tool_response: {content: "a line with \"quotes\" and a {brace}"}}'
}

# fire <project> <session> — run the hook once and print what the model would get.
fire() {
  tool_payload "${2:-}" | CLAUDE_PROJECT_DIR="$1" "$HOOK" 2>/dev/null
}

# ─── The hook the settings point at must exist and run ───────────────────────

test_the_reinjection_hook_is_executable() {
  assert_file "$HOOK" "the rules re-injection hook is missing"
  [ -x "$HOOK" ] || fail "the hook is not executable — Claude Code cannot run it: $HOOK"
}

test_the_installer_points_at_the_shipped_hook() {
  load_init
  # The installer writes the path with $CLAUDE_PROJECT_DIR unexpanded; the
  # session expands it to the project root, where .agents is the checkout.
  assert_contains "$REINJECT_HOOK_CMD" '$CLAUDE_PROJECT_DIR' \
    "the hook command is not anchored to the project directory"
  local suffix="${REINJECT_HOOK_CMD#*/.agents/}"
  assert_file "$REPO_ROOT/${suffix%\"}" \
    "the installer points at a script that does not exist in this checkout"
}

# ─── The settings the installer writes must be the shape the CLI reads ───────

test_installed_settings_carry_both_hooks() {
  command -v jq >/dev/null 2>&1 || skip "jq is not on PATH"
  load_init
  local proj="$SANDBOX/project"
  mkdir -p "$proj"

  set_allow_all_hook "$proj" >/dev/null
  set_rules_reinject_hook "$proj" >/dev/null

  local settings="$proj/.claude/settings.json"
  assert_file "$settings" "the installer wrote no settings file"
  # The re-injection rides the tool stream, which is what buries the rules.
  assert_json "$settings" '.hooks.PostToolUse[0].hooks[0].type' "command" \
    "the re-injection hook is not a PostToolUse command hook"
  assert_json "$settings" '.hooks.PreToolUse[0].hooks[0].type' "command" \
    "the allow-all hook is not a PreToolUse command hook"
}

test_installing_migrates_the_old_userpromptsubmit_wiring() {
  command -v jq >/dev/null 2>&1 || skip "jq is not on PATH"
  load_init
  local proj="$SANDBOX/project"
  mkdir -p "$proj/.claude"
  # What an install from before the move to PostToolUse left behind.
  jq -n --arg cmd "$REINJECT_HOOK_CMD" \
    '{hooks: {UserPromptSubmit: [{hooks: [{type: "command", command: $cmd}]}]}}' \
    >"$proj/.claude/settings.json"

  set_rules_reinject_hook "$proj" >/dev/null

  local settings="$proj/.claude/settings.json"
  assert_json "$settings" '.hooks | has("UserPromptSubmit")' "false" \
    "the old prompt hook survived — the rules now inject twice"
  assert_json "$settings" '[.hooks.PostToolUse[].hooks[].command] | length' "1" \
    "the migration did not leave exactly one re-injection hook"
}

test_reinstalling_does_not_duplicate_the_hooks() {
  command -v jq >/dev/null 2>&1 || skip "jq is not on PATH"
  load_init
  local proj="$SANDBOX/project"
  mkdir -p "$proj"

  local _run
  for _run in 1 2 3; do
    set_allow_all_hook "$proj" >/dev/null
    set_rules_reinject_hook "$proj" >/dev/null
  done

  local settings="$proj/.claude/settings.json"
  assert_json "$settings" '[.hooks.PostToolUse[].hooks[].command] | length' "1" \
    "three installs left more than one re-injection hook — the rules inject twice per tool call"
  assert_json "$settings" '[.hooks.PreToolUse[].hooks[].command] | length' "1" \
    "three installs left more than one allow-all hook"
}

test_uninstall_removes_the_hooks_it_installed() {
  command -v jq >/dev/null 2>&1 || skip "jq is not on PATH"
  load_init
  local proj="$SANDBOX/project"
  mkdir -p "$proj/.claude"
  # A hook the operator owns. Uninstall must leave it alone.
  jq -n '{hooks: {PostToolUse: [{hooks: [{type: "command", command: "echo mine"}]}]}}' \
    >"$proj/.claude/settings.json"

  set_allow_all_hook "$proj" >/dev/null
  set_rules_reinject_hook "$proj" >/dev/null
  del_allow_all_hook "$proj" >/dev/null
  del_rules_reinject_hook "$proj" >/dev/null

  local settings="$proj/.claude/settings.json"
  assert_json "$settings" '[.hooks.PostToolUse[].hooks[].command] | join(",")' "echo mine" \
    "uninstall did not restore the operator's own hooks"
  assert_json "$settings" '.hooks | has("PreToolUse")' "false" \
    "uninstall left the allow-all hook behind"
}

# ─── The hook must answer in the form PostToolUse reads ──────────────────────
#
# PostToolUse ignores stdout. Anything the model must see goes in
# hookSpecificOutput.additionalContext, so the answer has to be valid JSON.

test_the_hook_answers_a_tool_payload_with_valid_json() {
  command -v jq >/dev/null 2>&1 || skip "jq is not on PATH"
  local proj="$SANDBOX/project"
  make_project "$proj"

  local out status
  out="$(BYRDE_RULES_REINJECT_EVERY=1 fire "$proj")"
  status=$?

  assert_status 0 "$status" "the hook exited non-zero"
  printf '%s' "$out" | jq -e . >/dev/null 2>&1 \
    || fail "the hook did not emit valid JSON: $(printf '%s' "$out" | head -c 300)"
  assert_eq "PostToolUse" "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.hookEventName')" \
    "the hook names the wrong event"

  local ctx
  ctx="$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext')"
  assert_contains "$ctx" "GLOBAL_RULE_MARKER" "the injection does not carry the lead rule"
  assert_contains "$ctx" "project-rules-reinjected" "the injection is not marked as a rules block"
}

test_the_hook_injects_the_short_form() {
  command -v jq >/dev/null 2>&1 || skip "jq is not on PATH"
  local proj="$SANDBOX/project"
  make_project "$proj"

  local ctx
  ctx="$(BYRDE_RULES_REINJECT_EVERY=1 fire "$proj" | jq -r '.hookSpecificOutput.additionalContext')"

  # The lead rule in full, the rest by name only. Repeating every rule file on a
  # tool-call cadence would eat the context the rules are meant to protect.
  assert_contains "$ctx" "GLOBAL_RULE_MARKER" "the lead rule is missing"
  assert_not_contains "$ctx" "DEVELOPMENT_RULE_MARKER" \
    "the injection carries a second rule body — the short form is not short"
  assert_contains "$ctx" "development.md" "the injection does not name the other rules"
  assert_not_contains "$ctx" "development.mdc" "the injection names a Cursor .mdc rule"
}

test_the_hook_holds_the_cadence_over_a_run_of_tool_calls() {
  command -v jq >/dev/null 2>&1 || skip "jq is not on PATH"
  local proj="$SANDBOX/project"
  make_project "$proj"

  # Twelve tool calls at the default cadence: silence, then one injection.
  local call fired=0 last=""
  for call in $(seq 1 12); do
    out="$(fire "$proj")"
    if [ -n "$out" ]; then fired=$((fired + 1)); last="$out"; fi
    if [ "$call" -lt 12 ] && [ -n "$out" ]; then
      fail "the hook injected on tool call $call — the default cadence is 12"
    fi
  done

  assert_eq "1" "$fired" "the hook did not inject exactly once in twelve tool calls"
  assert_eq "12" "$(printf '%s' "$last" | jq -r '.hookSpecificOutput.additionalContext' \
    | sed -n 's/.*after-tool-calls="\([0-9]*\)".*/\1/p')" \
    "the injection reports the wrong tool-call count"
  assert_eq "12" "$(cat "$proj/.claude/.byrde/rules-reinject.11111111-2222-3333-4444-555555555555")" \
    "the counter does not track every tool call"
}

test_a_broken_cadence_does_not_break_the_hook() {
  command -v jq >/dev/null 2>&1 || skip "jq is not on PATH"
  local proj="$SANDBOX/project"
  make_project "$proj"

  # A typo in the env var must not error on every tool call, and must not
  # re-inject on every tool call either. It falls back to the default.
  local out err
  out="$(BYRDE_RULES_REINJECT_EVERY=abc fire "$proj" 2>"$SANDBOX/err")"
  err="$(cat "$SANDBOX/err")"
  BYRDE_RULES_REINJECT_EVERY=abc fire "$proj" >/dev/null 2>>"$SANDBOX/err"

  assert_empty "$err" "a malformed cadence made the hook write an error"
  assert_empty "$out" "a malformed cadence made the hook inject on the first tool call"
}

test_disabling_the_cadence_silences_the_hook() {
  local proj="$SANDBOX/project"
  make_project "$proj"
  assert_empty "$(BYRDE_RULES_REINJECT_EVERY=0 fire "$proj")" \
    "the hook still injected with the cadence set to 0"
}

test_the_counter_is_per_session() {
  command -v jq >/dev/null 2>&1 || skip "jq is not on PATH"
  local proj="$SANDBOX/project"
  make_project "$proj"

  # Two sessions, cadence 2. Each must reach its own boundary independently.
  BYRDE_RULES_REINJECT_EVERY=2 fire "$proj" "session-a" >/dev/null
  assert_empty "$(BYRDE_RULES_REINJECT_EVERY=2 fire "$proj" "session-b")" \
    "a second session inherited the first session's count"
  assert_contains "$(BYRDE_RULES_REINJECT_EVERY=2 fire "$proj" "session-a")" \
    "project-rules-reinjected" "the first session did not reach its own cadence boundary"
}

# ─── The allow-all hook must answer in the form the CLI expects ──────────────

test_the_allow_all_hook_emits_the_decision_the_cli_reads() {
  command -v jq >/dev/null 2>&1 || skip "jq is not on PATH"
  load_init
  local out
  out="$(eval "$ALLOW_ALL_HOOK_CMD")"
  printf '%s' "$out" | jq -e . >/dev/null 2>&1 \
    || fail "the allow-all hook did not emit valid JSON: $out"
  assert_eq "allow" "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision')" \
    "the allow-all hook does not answer with an allow decision"
  assert_eq "PreToolUse" "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.hookEventName')" \
    "the allow-all hook names the wrong event"
}

run_tests
