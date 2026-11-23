#!/usr/bin/env bash
# test_spec_kit.sh — setup-spec-kit.sh asks the Spec Kit CLI for the right
# things, in an order that leaves a consistent install.
#
# Wiring layer: no network, no session, no cost.
#
# ## What these tests cover
#
# The script decides three things on its own, and each one failed at least once
# while it was written against the real CLI (v1.4.3):
#
#   - WHICH integrations. One per place the harnesses read skills from, not one
#     per harness: `claude` for .claude/skills/, `codex` for the shared
#     .agents/skills/. Two integrations that write the same folder would load
#     every skill twice.
#   - IN WHICH ORDER. A preset reaches the skills of the default integration
#     only, and `upgrade` refuses a skill that a preset rewrote unless it gets
#     --force. A first install that skipped either step left the CLI reporting
#     modified files, and the next run failed.
#   - WHAT IS COMMITTED. The CLI stamps the time into its state files on every
#     run. Committed, they change on every init and differ between developers.
#     The ignore block for them goes in the project's .gitignore, because the
#     CLI tracks .specify/.gitignore by hash and reports an edit there.
#
# ## How a test reaches the CLI without the CLI
#
# BYRDE_SPECIFY names the binary the script runs. Each test points it at a fake
# that appends its arguments to a log and keeps the two pieces of state the
# script reads back: the installed integrations and the installed presets. The
# assertions read the log. The real CLI was exercised by hand; the pull request
# that added this file records what was run.
#
# Run: .agents/tests/run.sh spec_kit
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/harness.sh"

# A host repo with this checkout at .agents.
make_host() {
  local host="$SANDBOX/host"
  mkdir -p "$host"
  git -C "$host" init -q
  rsync -a --exclude .git --exclude .worktrees "$REPO_ROOT/" "$host/.agents/"
  # Its own repo, as a submodule is, so "did the setup dirty it" has an answer.
  git -C "$host/.agents" init -q
  git -C "$host/.agents" add -A
  git -C "$host/.agents" -c user.email=t@t -c user.name=t -c commit.gpgsign=false commit -qm fixture
  echo "$host"
}

# The fake CLI. It runs in the project root, as the real one does.
make_fake_specify() {
  mkdir -p "$SANDBOX/bin"
  cat >"$SANDBOX/bin/specify" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "$*" >>"$FAKE_LOG"
state=.specify/integration.json
presets=.specify/presets/list
skills_of() { case "$1" in claude) echo .claude/skills ;; *) echo .agents/skills ;; esac; }
write_skills() { mkdir -p "$(skills_of "$1")/speckit-specify"; echo "$1" >"$(skills_of "$1")/speckit-specify/SKILL.md"; }
case "$1 ${2:-}" in
  "init "*)
    key=""; prev=""
    for a in "$@"; do [[ "$prev" == "--integration" ]] && key="$a"; prev="$a"; done
    mkdir -p .specify/memory .specify/templates .specify/presets
    echo "[PROJECT_NAME] Constitution" >.specify/templates/constitution-template.md
    [[ -f .specify/memory/constitution.md ]] || cp .specify/templates/constitution-template.md .specify/memory/constitution.md
    [[ -f .specify/.gitignore ]] || echo "feature.json" >.specify/.gitignore
    jq -n --arg k "$key" '{installed_integrations: [$k], default_integration: $k}' >"$state"
    write_skills "$key" ;;
  "integration install")
    jq --arg k "$3" '.installed_integrations += [$k]' "$state" >"$state.tmp" && mv "$state.tmp" "$state"
    write_skills "$3" ;;
  "integration upgrade") write_skills "$3" ;;
  "integration use")
    jq --arg k "$3" '.default_integration = $k' "$state" >"$state.tmp" && mv "$state.tmp" "$state" ;;
  "integration uninstall")
    jq --arg k "$3" '.installed_integrations -= [$k]' "$state" >"$state.tmp" && mv "$state.tmp" "$state"
    rm -rf "$(skills_of "$3")/speckit-specify" ;;
  "preset list") [[ -f "$presets" ]] && cat "$presets" || true ;;
  "preset add")
    if [[ "$3" == "--dev" ]]; then echo "Byrde Agents (byrde)" >>"$presets"; else echo "Lean Workflow ($3)" >>"$presets"; fi ;;
  "preset remove") grep -v "($3)" "$presets" >"$presets.tmp" || true; mv "$presets.tmp" "$presets" ;;
esac
EOF
  chmod +x "$SANDBOX/bin/specify"
  FAKE_LOG="$SANDBOX/specify.log"
  : >"$FAKE_LOG"
  export FAKE_LOG
}

# run_setup <host> <harnesses> [args…]
run_setup() {
  local host="$1" harnesses="$2"
  shift 2
  (cd "$host" && BYRDE_HARNESSES="$harnesses" BYRDE_SPECIFY="$SANDBOX/bin/specify" \
     .agents/scripts/setup/setup-spec-kit.sh "$@" </dev/null 2>&1)
}

need() { command -v jq >/dev/null 2>&1 && command -v rsync >/dev/null 2>&1 || skip "jq and rsync are needed"; }

setup() {
  need
  HOST="$(make_host)"
  make_fake_specify
}

integrations() { jq -r '.installed_integrations | join(" ")' "$HOST/.specify/integration.json"; }

# ─── Which integrations ──────────────────────────────────────────────────────

test_claude_alone_gets_the_claude_integration() {
  setup
  run_setup "$HOST" claude >/dev/null || fail "setup failed"
  assert_eq "claude" "$(integrations)" "Claude Code alone needs only its own skills folder"
}

test_every_other_harness_shares_one_integration() {
  # Cursor, Codex, Copilot and Antigravity all read .agents/skills/. One
  # integration per harness would write that folder four times.
  setup
  run_setup "$HOST" "cursor codex copilot antigravity" >/dev/null || fail "setup failed"
  assert_eq "codex" "$(integrations)" "the shared folder got more than one integration"
  assert_file "$HOST/.agents/skills/speckit-specify/SKILL.md" "the shared folder got no skills"
  assert_empty "$(git -C "$HOST/.agents" status --short)" "the generated skills dirtied the shared checkout"
}

test_all_harnesses_get_both_and_claude_is_the_default() {
  setup
  run_setup "$HOST" all >/dev/null || fail "setup failed"
  assert_eq "codex claude" "$(integrations)" "a mixed selection needs both folders"
  assert_json "$HOST/.specify/integration.json" '.default_integration' "claude" "the default is not Claude Code"
}

test_an_opencode_project_gets_the_shared_skills() {
  # OpenCode has its own installer, so it is not in the harness list. It reads
  # .agents/skills/ all the same.
  setup
  mkdir -p "$HOST/.opencode"
  run_setup "$HOST" claude >/dev/null || fail "setup failed"
  assert_eq "codex claude" "$(integrations)" "OpenCode got no Spec Kit skills"
}

test_a_dropped_harness_loses_its_integration() {
  setup
  run_setup "$HOST" all >/dev/null || fail "setup failed"
  run_setup "$HOST" cursor >/dev/null || fail "the re-run failed"
  assert_eq "codex" "$(integrations)" "Claude Code kept its integration after being dropped"
  assert_no_file "$HOST/.claude/skills/speckit-specify/SKILL.md" "Claude Code kept its Spec Kit skills"
  assert_json "$HOST/.specify/integration.json" '.default_integration' "codex" \
    "the default still names an integration that is gone"
}

# ─── In which order ──────────────────────────────────────────────────────────

test_a_first_install_writes_the_skills_after_the_presets() {
  setup
  run_setup "$HOST" all >/dev/null || fail "setup failed"
  local log; log="$(cat "$FAKE_LOG")"
  assert_contains "$log" "init --here --force --non-interactive --ignore-agent-tools --integration codex" \
    "init did not run unattended, or did not skip the check for the agent's own CLI"
  assert_contains "$log" "/host/.agents/spec-kit/preset --priority 5" \
    "the byrde preset does not win over lean"
  # The order is the point: presets, then a forced rewrite, then each
  # integration as the default in turn.
  local order
  order="$(grep -n -E '^(preset add lean|integration upgrade codex --force|integration use codex|integration use claude)$' "$FAKE_LOG" | cut -d: -f2 | tr '\n' ';')"
  assert_eq "preset add lean;integration upgrade codex --force;integration use codex;integration use claude;" "$order" \
    "the skills were not rewritten after the presets, in the order that applies them"
}

test_a_rerun_restores_the_skills_and_refreshes_the_preset() {
  setup
  run_setup "$HOST" all >/dev/null || fail "setup failed"
  # A fresh clone has the committed record and none of the generated skills.
  rm -rf "$HOST/.claude/skills/speckit-specify" "$HOST/.agents/skills/speckit-specify"
  : >"$FAKE_LOG"
  run_setup "$HOST" all >/dev/null || fail "the re-run failed"
  local log; log="$(cat "$FAKE_LOG")"
  assert_not_contains "$log" "init " "a re-run initialized the project again"
  assert_not_contains "$log" "preset add lean" "a re-run added lean twice"
  assert_contains "$log" "preset remove byrde" "a re-run kept the old copy of the byrde preset"
  assert_file "$HOST/.claude/skills/speckit-specify/SKILL.md" "the Claude Code skills were not restored"
  assert_file "$HOST/.agents/skills/speckit-specify/SKILL.md" "the shared skills were not restored"
}

# ─── What is committed ───────────────────────────────────────────────────────

test_the_per_machine_state_is_ignored_once() {
  setup
  run_setup "$HOST" claude >/dev/null || fail "setup failed"
  run_setup "$HOST" claude >/dev/null || fail "the re-run failed"
  assert_eq "1" "$(grep -c -x '.specify/integration.json' "$HOST/.gitignore")" \
    "the ignore block is missing, or written twice"
  # The CLI tracks its own ignore file by hash. An edit there is a warning in
  # every later status report.
  assert_eq "feature.json" "$(cat "$HOST/.specify/.gitignore")" "the setup edited a file that the CLI tracks"
  git -C "$HOST" add -A .specify
  assert_empty "$(git -C "$HOST" ls-files .specify/integration.json .specify/presets)" \
    "state that changes on every run would be committed"
  assert_contains "$(git -C "$HOST" ls-files .specify)" ".specify/memory/constitution.md" \
    "the constitution would not be committed"
}

test_the_constitution_points_at_the_rules_until_the_project_edits_it() {
  setup
  run_setup "$HOST" claude >/dev/null || fail "setup failed"
  local live="$HOST/.specify/memory/constitution.md"
  assert_contains "$(cat "$live")" ".agents/rules/" "the empty template was left in place"
  echo "OUR_PRINCIPLE" >>"$live"
  run_setup "$HOST" claude >/dev/null || fail "the re-run failed"
  assert_contains "$(cat "$live")" "OUR_PRINCIPLE" "a re-run overwrote the project's constitution"
}

# ─── Without the CLI, and uninstall ──────────────────────────────────────────

test_no_cli_is_a_skip_for_init_and_a_failure_alone() {
  setup
  local out status
  out="$(cd "$HOST" && BYRDE_HARNESSES=claude BYRDE_SPECIFY="$SANDBOX/no-such-binary" \
    .agents/scripts/setup/setup-spec-kit.sh --optional 2>&1)"; status=$?
  assert_status 0 "$status" "a missing CLI failed the optional run that init makes"
  assert_contains "$out" "docs.astral.sh/uv" "the skip does not say how to get the CLI"
  (cd "$HOST" && BYRDE_HARNESSES=claude BYRDE_SPECIFY="$SANDBOX/no-such-binary" \
    .agents/scripts/setup/setup-spec-kit.sh >/dev/null 2>&1); status=$?
  assert_status 1 "$status" "a missing CLI passed when the user ran the script directly"
  assert_no_file "$HOST/.specify/integration.json" "something was written without the CLI"
}

test_uninstall_removes_the_skills_and_keeps_the_record() {
  setup
  run_setup "$HOST" all >/dev/null || fail "setup failed"
  mkdir -p "$HOST/specs/42-export-csv" && echo "# Spec" >"$HOST/specs/42-export-csv/spec.md"
  run_setup "$HOST" all uninstall >/dev/null || fail "uninstall failed"
  assert_no_file "$HOST/.claude/skills/speckit-specify/SKILL.md" "uninstall left the Claude Code skills"
  assert_no_file "$HOST/.agents/skills/speckit-specify/SKILL.md" "uninstall left the shared skills"
  assert_file "$HOST/specs/42-export-csv/spec.md" "uninstall removed a spec"
  assert_file "$HOST/.specify/memory/constitution.md" "uninstall removed the constitution"
}

# ─── init.sh ─────────────────────────────────────────────────────────────────

run_init() {
  (cd "$1" && shift && HOME="$SANDBOX/home" CLAUDE_USER_CONFIG="$SANDBOX/claude.json" \
     BYRDE_HARNESSES= BYRDE_SPECIFY="$SANDBOX/bin/specify" .agents/scripts/init.sh "$@" </dev/null >/dev/null 2>&1)
}

test_init_installs_spec_kit_unless_told_not_to() {
  setup
  echo '{}' >"$SANDBOX/claude.json"
  run_init "$HOST" --harness claude --no-spec-kit || fail "init --no-spec-kit failed"
  assert_no_file "$HOST/.specify/integration.json" "--no-spec-kit installed Spec Kit"
  run_init "$HOST" --harness claude || fail "init failed"
  assert_eq "claude" "$(integrations)" "init did not install Spec Kit"
  assert_file "$HOST/.claude/skills/speckit-specify/SKILL.md" "init did not install the Spec Kit skills"
}

test_init_leaves_the_spec_kit_skills_to_the_cli() {
  # init copies every shared skill in .agents/skills/ into .claude/skills/. The
  # Spec Kit ones land in that folder too, and they belong to the CLI: a copy
  # would break the hashes it keeps.
  # shellcheck disable=SC1091
  . "$REPO_ROOT/scripts/lib/layout.sh"
  is_tool_skill speckit-specify || fail "init would copy a Spec Kit skill as one of its own"
  is_tool_skill review && fail "review is no longer a shared skill"
  return 0
}

test_a_failed_setup_does_not_fail_init() {
  setup
  echo '{}' >"$SANDBOX/claude.json"
  printf '#!/usr/bin/env bash\necho boom >&2\nexit 1\n' >"$SANDBOX/bin/specify"
  run_init "$HOST" --harness claude || fail "a Spec Kit failure stopped the whole install"
  assert_file "$HOST/.claude/rules/global.md" "the rules were not installed"
}

# ─── What ships ──────────────────────────────────────────────────────────────

test_the_preset_and_the_rule_name_things_that_exist() {
  local preset="$REPO_ROOT/spec-kit/preset" file
  file="$(sed -n 's/^ *file: "\(.*\)"$/\1/p' "$preset/preset.yml")"
  assert_file "$preset/$file" "preset.yml names a command file that does not ship"
  assert_file "$REPO_ROOT/spec-kit/constitution.md" "the constitution does not ship"
  # doctor.sh tells the byrde specify prompt from the lean one by this sentence.
  assert_contains "$(cat "$preset/$file")" "Do not ask the user for it" \
    "the sentence doctor.sh looks for is gone from the specify prompt"
  # The rule drives the phases by skill name. A renamed phase must fail here.
  local rule name
  rule="$(cat "$REPO_ROOT/rules/global.md")"
  for name in speckit-specify speckit-plan speckit-tasks speckit-implement speckit-converge; do
    assert_contains "$rule" "\`$name\`" "the global rule does not name the $name phase"
  done
  [ ! -d "$REPO_ROOT/skills/brainstorm" ] || fail "brainstorm still ships beside the specify phase"
  [ ! -d "$REPO_ROOT/skills/plan" ] || fail "plan still ships beside the Spec Kit phases"
}

run_tests
