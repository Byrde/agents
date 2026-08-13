# Tests

The suite answers one question about the hooks: **in a real Claude Code
session, does the hook run mid-loop, and does what it emits reach the model?**

```bash
.agents/tests/run.sh          # everything, including the live session tests
.agents/tests/run.sh live     # run one file by name
```

The runner exits 0 when every test passes. It needs the `claude` CLI on `PATH`
and logged in.

## The two layers

**Wiring tests** (`test_hook_wiring.sh`) start no session and cost nothing. They
guard the two ways a hook dies without a sound: the settings point at a script
that no longer exists, or the hook answers the CLI in a form the CLI rejects.

**Live tests** (`test_hooks_live.sh`) start the `claude` CLI, so they call the
API and cost money. They always run. A test skips only when the machine cannot
run it — no `claude` on `PATH`, or no `jq`.

| Live test | What it proves |
| --- | --- |
| `posttooluse_injection_reaches_the_model_mid_loop` | The session runs the hook between tool calls, the hook answers through `additionalContext`, and the model reads the injected block back. |
| `without_the_hook_no_rules_block_appears` | The control. Same project, same prompt, no hook, no block. Without this, the test above proves nothing. |
| `pretooluse_allow_hook_approves_a_tool_call` | The allow-all hook runs a Bash call under `--permission-mode default` with no denial. |

### Why the live test asks about an attribute

Claude Code loads `.claude/rules/*.md` on its own, so a marker in a rule file
proves nothing — the model would see it with the hook dead. The hook wraps its
injection in `<project-rules-reinjected after-tool-calls="N">`, and that
attribute exists nowhere else. The test drives two tool calls at cadence 2, then
asks the model to read the value back. Only the hook can put it there.

## How a live test observes a session

Each turn runs headless and writes a `stream-json` transcript:

```bash
claude -p "<prompt>" --output-format stream-json --include-hook-events \
       --verbose --setting-sources project
```

`--include-hook-events` puts every hook in the stream. A command hook appears as
a `hook_started` event and then a `hook_response` event that carries `output`,
`stderr`, and `exit_code`. `tests/lib/claude.sh` reads those with `hook_output`,
`hook_stderr`, `hook_exit_codes`, and `hook_ran`.

`--setting-sources project` keeps the sandbox honest. The run reads the sandbox
`.claude/settings.json` and ignores your user settings, so a hook you configured
in `~/.claude` cannot make a test pass.

`--session-id` opens a session and `--resume` adds turns to it, for a test that
needs more than one of your messages.

Transcript evidence proves the hook ran. Only the model's answer proves the
output reached the context, so the tests that matter most assert on
`result_text`.

### The channel matters

`PostToolUse` ignores stdout. A hook that prints its rules the way a
`UserPromptSubmit` hook does runs, exits 0, and shows its output in the
transcript — while the model sees nothing. The live test asserts on
`additionalContext` for that reason, and a mutant hook that answers on stdout
fails it.

## Cost and speed

The live suite runs three turns. A turn on Haiku costs about two cents and takes
a few seconds. The whole suite finishes in about 20 seconds. Override the model
with `BYRDE_TEST_MODEL`, and the per-turn ceiling with `BYRDE_TEST_BUDGET_USD`
(default `0.50`).

Turns are the whole cost. Keep a new test to the fewest turns that still show
the behavior, and keep the prompts short.

## Writing a test

A test file sources the harness, defines `test_*` functions, and calls
`run_tests`. Each test runs in a subshell with `$SANDBOX`, a fresh temporary
directory that the harness deletes afterward. A failed assertion prints the
reason and ends that test. The rest of the file still runs.

```bash
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/harness.sh"
. "$TESTS_DIR/lib/claude.sh"     # live tests only

test_my_hook_injects() {
  require_live                    # skips when the claude CLI is unavailable
  local proj="$SANDBOX/project"
  live_project "$proj"
  write_hook_settings "$proj" PostToolUse "$MY_HOOK"
  claude_turn "$proj" "$SANDBOX/turn.jsonl" "Read a.txt, then …" \
    --permission-mode bypassPermissions
  assert_turn_ok "$SANDBOX/turn.jsonl" "the live turn failed"
  assert_contains "$(hook_output "$SANDBOX/turn.jsonl" PostToolUse)" "additionalContext" \
    "the hook answered on a channel the model cannot read"
  assert_contains "$(result_text "$SANDBOX/turn.jsonl")" "ABC-123" "the model never saw it"
}

run_tests
```

Assertions: `assert_eq`, `assert_contains`, `assert_not_contains`,
`assert_empty`, `assert_status`, `assert_file`, `assert_no_file`, `assert_json`,
`fail`, `skip`.

## Check that a new test can fail

A test that cannot fail is worth nothing. Point the test at a broken hook —
`#!/usr/bin/env bash` and `exit 0` is enough — and confirm it goes red before
you keep it.
