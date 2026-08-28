#!/usr/bin/env bash
# test_figma_setup.sh — setup-figma.sh tells you WHY a Figma call failed, and
# installs without one.
#
# ## Why these tests exist
#
# Figma renamed Projects to Folders and retired the scopes its own
# `/v1/teams/:id/projects` endpoint still demands. A token holding every scope
# the current UI offers gets a 403 from that endpoint, and the response names
# the accepted scopes exactly.
#
# The script threw that response away. `figma_get` ran `curl -sf … 2>/dev/null`:
# `-f` discards the body on HTTP >= 400 and the redirect discards stderr. The
# caller then printed a hardcoded guess — "check permissions or team ID" — which
# is not what happened and sent the reader looking at the team ID.
#
# So the first test is about EVIDENCE, and it is the one that matters: the
# status code and the body have to reach the person running the script.
#
# ## How a test reaches the network layer without a network
#
# `curl` is resolved from `PATH`, so each test puts a fake `curl` earlier on
# `PATH` than the real one. It prints a canned body and exits with the status
# the case needs. No token, no Figma account, no traffic.
#
# `SETUP_FIGMA_SOURCED_ONLY=1` stops the script running `main`, so a test can
# call one function. Without it, sourcing the file starts the installer.
#
# Run: .agents/tests/run.sh figma_setup

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/harness.sh"

SETUP_FIGMA="$REPO_ROOT/scripts/setup/setup-figma.sh"

# A `curl` that answers every request the same way.
#
# It emulates the one flag combination `figma_get` uses: no `-f`, and
# `-w '\n%{http_code}'`. Real curl under those flags **exits 0 on a 4xx** and
# appends the status to the body on its own line. A fake that exited non-zero
# for an HTTP error would be testing the old flags, not the new ones.
#
# @param $1  the HTTP status to append
# @param $2  the response body
# @param $3  curl's own exit status, default 0. Non-zero models a transport
#            failure, where curl reports `000` and never saw an HTTP response.
fake_curl() {
  local http="$1" body="$2" exit_status="${3:-0}"
  mkdir -p "$SANDBOX/bin"
  cat >"$SANDBOX/bin/curl" <<EOF
#!/usr/bin/env bash
# Every argument is ignored. The cases vary the ANSWER, never the request.
printf '%s\n%s' '$body' '$http'
exit $exit_status
EOF
  chmod +x "$SANDBOX/bin/curl"
  PATH="$SANDBOX/bin:$PATH"
  export PATH
}

# Source the script for its functions, then hand flow control back to the test.
#
# The script runs under `set -e`. Left on, the first failing call under test
# would kill the test subshell before a single assertion ran.
load_setup_figma() {
  # shellcheck disable=SC1090
  SETUP_FIGMA_SOURCED_ONLY=1 . "$SETUP_FIGMA" >/dev/null 2>&1
  set +e
}

# The 403 Figma actually returns for a token carrying only current scopes.
FIGMA_403_BODY='{"error":true,"status":403,"message":"Invalid scope: [\"file_content:read\", \"folders:read\"]. This endpoint requires the file_read or files:read or projects:read scope.","i18n":null}'

test_figma_get_reports_the_status_and_the_body() {
  # The whole point. A caller cannot explain a failure it never saw.
  fake_curl 403 "$FIGMA_403_BODY"
  load_setup_figma

  local out
  out="$(FIGMA_TOKEN=irrelevant figma_get "/v1/teams/123/projects" 2>&1)"

  assert_contains "$out" "403" "the HTTP status never reached the caller"
  assert_contains "$out" "projects:read" \
    "the body naming the required scope was discarded — this is the defect"
}

test_figma_get_still_fails_when_the_call_fails() {
  # Surfacing the reason must not turn a failure into a success.
  fake_curl 403 "$FIGMA_403_BODY"
  load_setup_figma

  FIGMA_TOKEN=irrelevant figma_get "/v1/teams/123/projects" >/dev/null 2>&1
  assert_eq "1" "$?" "figma_get reported success for a 403"
}

test_figma_get_returns_the_body_on_success() {
  fake_curl 200 '{"name":"Design","projects":[{"id":"1","name":"Tokens"}]}'
  load_setup_figma

  local out
  out="$(FIGMA_TOKEN=irrelevant figma_get "/v1/teams/123/projects" 2>/dev/null)"

  assert_contains "$out" "Tokens" "a successful call lost its body"
  assert_not_contains "$out" "200" "the status was left in the body it returned"
}

test_figma_get_does_not_report_000_as_an_http_status() {
  # curl answers `000` when nothing was served. Printing "returned HTTP 000"
  # would send the reader hunting for a status code that does not exist.
  fake_curl 000 "" 7
  load_setup_figma

  local out
  out="$(FIGMA_TOKEN=irrelevant figma_get "/v1/teams/123/projects" 2>&1)"

  assert_contains "$out" "did not reach Figma" "a transport failure was mislabelled"
  assert_not_contains "$out" "HTTP 000" "curl's no-answer sentinel was reported as a status"
}

test_sourcing_does_not_run_the_installer() {
  # The guard the tests above depend on. Without it, sourcing prompts for a
  # token and starts writing config into the sandbox.
  fake_curl 0 '{}'

  local out
  out="$(SETUP_FIGMA_SOURCED_ONLY=1 . "$SETUP_FIGMA" 2>&1 </dev/null)"

  assert_not_contains "$out" "Paste your Figma" "sourcing the script ran main"
  assert_not_contains "$out" "Installing figma-use" "sourcing the script ran main"
}

test_extract_team_id_reads_a_team_url() {
  local out
  out="$(
    SETUP_FIGMA_SOURCED_ONLY=1 . "$SETUP_FIGMA" >/dev/null 2>&1
    extract_team_id "https://www.figma.com/files/team/1599422031472407732/Some-Team"
  )"
  assert_eq "1599422031472407732" "$out" "a team URL did not yield its ID"
}

test_install_needs_no_token() {
  # The token was only ever discovery convenience: it is read, exported, used in
  # one call, and written to no file. The MCP server authenticates over OAuth in
  # the editor. So a install must be possible with no token at all — otherwise a
  # Figma-side rename can block a install that never needed the API.
  #
  # Asserted against the SCRIPT, because a claim about what a prompt asks for is
  # a claim about its text.
  local text
  text="$(cat "$SETUP_FIGMA")"

  assert_not_contains "$text" 'read -r -s -p "Paste your Figma Personal Access Token: "' \
    "the installer still demands a token on the happy path"
  assert_contains "$text" "FIGMA_TOKEN:-" \
    "there is no way to supply a token without being prompted for one"
}

test_prose_says_folder_and_the_api_still_says_projects() {
  # Figma renamed Projects to Folders in the product. The API did not: the path
  # is still /v1/teams/:id/projects and the field is still .projects[]. The
  # writing rule is explicit — never change an API name to satisfy a wording
  # rule — so the two must disagree on purpose.
  local text
  text="$(cat "$SETUP_FIGMA")"

  assert_contains "$text" "/v1/teams/\$team_id/projects" \
    "the API path was renamed and now points at nothing"
  assert_contains "$text" ".projects[]" \
    "the API response field was renamed and now reads nothing"
  assert_contains "$text" "Folder" "no human-facing text mentions a Folder"
}

run_tests
