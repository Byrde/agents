#!/usr/bin/env bash
# test_hooks_live.sh — prove the hooks work inside a real Claude Code session.
#
# Every test here starts the `claude` CLI, so it calls the API and costs money.
# See tests/README.md.
#
# The question these answer is not "does the script work" — it is "does the
# session run the hook mid-loop, and does what the hook emits reach the model".
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/harness.sh"
. "$TESTS_DIR/lib/claude.sh"

HOOK="$REPO_ROOT/scripts/hooks/reinject-rules.sh"

# The prompt drives two tool calls and then asks the model to report a marker
# that exists ONLY in the hook output. The rule FILE is loaded natively by the
# session, so nothing in the file can prove the hook did anything. The
# after-tool-calls attribute can.
LOOP_PROMPT='Read a.txt and b.txt with the Read tool. Then answer this: does your context contain a project-rules-reinjected block? If it does, reply with the value of its after-tool-calls attribute and nothing else. If it does not, reply NONE.'

# ─── Does the hook reach the model during the working loop? ──────────────────

test_posttooluse_injection_reaches_the_model_mid_loop() {
  require_live
  [ -x "$HOOK" ] || fail "the hook script is missing or not executable: $HOOK"

  local proj="$SANDBOX/project"
  live_project "$proj"
  write_hook_settings "$proj" PostToolUse "$HOOK"
  echo "alpha" >"$proj/a.txt"
  echo "beta" >"$proj/b.txt"

  # Cadence 2: the first tool call stays silent, the second injects.
  BYRDE_RULES_REINJECT_EVERY=2 \
    claude_turn "$proj" "$SANDBOX/turn.jsonl" "$LOOP_PROMPT" --permission-mode bypassPermissions
  assert_turn_ok "$SANDBOX/turn.jsonl" "the live turn failed"

  local fires
  fires="$(hook_ran "$SANDBOX/turn.jsonl" PostToolUse)"
  assert_eq "yes" "$fires" "the session never ran the PostToolUse hook"
  assert_empty "$(hook_stderr "$SANDBOX/turn.jsonl" PostToolUse)" \
    "the hook wrote to stderr during the loop"

  # The hook answered with the channel PostToolUse actually reads.
  local out
  out="$(hook_output "$SANDBOX/turn.jsonl" PostToolUse)"
  assert_contains "$out" "additionalContext" \
    "the hook did not answer through additionalContext — PostToolUse ignores plain stdout"
  assert_contains "$out" "project-rules-reinjected" "the hook did not re-inject the rules"

  # The model reporting the attribute is the proof it entered the context window.
  assert_contains "$(result_text "$SANDBOX/turn.jsonl")" "2" \
    "the model could not see the injected rules block"
}

# The control. Same project, same prompt, no hook. Without this, the test above
# proves nothing — the model could be guessing, or reading the rule file the
# session loads on its own.
test_without_the_hook_no_rules_block_appears() {
  require_live
  local proj="$SANDBOX/project"
  live_project "$proj"
  mkdir -p "$proj/.claude"
  echo '{}' >"$proj/.claude/settings.json"
  echo "alpha" >"$proj/a.txt"
  echo "beta" >"$proj/b.txt"

  claude_turn "$proj" "$SANDBOX/turn.jsonl" "$LOOP_PROMPT" --permission-mode bypassPermissions
  assert_turn_ok "$SANDBOX/turn.jsonl" "the live turn failed"

  assert_eq "no" "$(hook_ran "$SANDBOX/turn.jsonl" PostToolUse)" \
    "a hook ran even though the project configured none"
  assert_contains "$(result_text "$SANDBOX/turn.jsonl")" "NONE" \
    "the model reported a rules block with no hook to inject one"
}

# ─── Does the allow-all PreToolUse hook actually approve? ────────────────────
#
# The other hook init.sh installs. It claims to approve every tool call without
# a prompt. In a headless run an unapproved tool call is denied, so a successful
# Bash call with permission-mode default is the proof.

test_pretooluse_allow_hook_approves_a_tool_call() {
  require_live
  local proj="$SANDBOX/project"
  live_project "$proj"
  write_hook_settings "$proj" PreToolUse \
    "echo '{\"hookSpecificOutput\":{\"hookEventName\":\"PreToolUse\",\"permissionDecision\":\"allow\",\"permissionDecisionReason\":\"byrde-agents allow-all auto-approve\"}}'"
  echo "MANGO-LEDGER-2208" >"$proj/canary.txt"

  claude_turn "$proj" "$SANDBOX/turn.jsonl" \
    "Run: cat canary.txt — then reply with the file's contents and nothing else." \
    --permission-mode default
  assert_turn_ok "$SANDBOX/turn.jsonl" "the live turn failed"

  assert_eq "yes" "$(hook_ran "$SANDBOX/turn.jsonl" PreToolUse)" \
    "the session did not run the PreToolUse hook"
  assert_eq "0" "$(permission_denials "$SANDBOX/turn.jsonl")" \
    "a tool call was denied even though the hook allows every call"
  assert_contains "$(result_text "$SANDBOX/turn.jsonl")" "MANGO-LEDGER-2208" \
    "the tool call never produced the file contents"
}

run_tests
