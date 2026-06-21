#!/usr/bin/env bash
# Configure the google-analytics tool skill: pin a GA4 property, establish
# Application Default Credentials via gcloud, and register Google's official
# Analytics MCP server (analytics-mcp, run via pipx) in the project configs.
#
# Mirrors setup-github-project.sh / setup-figma.sh: it installs a tool skill,
# pins identity (the Google account's ADC + GCP project + GA4 property), wires
# the MCP server into .mcp.json / .cursor/mcp.json, records the capability in the
# manifest, and ships an uninstall path.
#
# Auth model — NO SECRETS ON DISK (the house invariant):
#   The GA MCP authenticates with Application Default Credentials. `gcloud auth
#   application-default login` writes the credentials to gcloud's well-known ADC
#   store; analytics-mcp's google-auth library auto-discovers them there. So the
#   MCP config carries ONLY GOOGLE_PROJECT_ID (the quota/billing project — not a
#   secret), never a credentials path or token. Same spirit as the GitHub MCP's
#   live headersHelper: nothing sensitive is written into .mcp.json.
#
# Run from the folder your agent opens in (the one that contains .agents):
#   cd /your/workspace && /path/to/setup-google-analytics.sh
#
# Writes:
#   - skills/google-analytics/SKILL.md (+ mirrored into .claude/ and .cursor/)
#   - .mcp.json / .cursor/mcp.json — registers the analytics-mcp server
#
# Requires: gcloud (authenticated), pipx, jq, python3. Bash 3.2 (macOS) compatible.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENTS_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=lib/layout.sh
. "$SCRIPT_DIR/../lib/layout.sh"
resolve_layout
# shellcheck source=lib/manifest.sh
. "$SCRIPT_DIR/../lib/manifest.sh"
TOOL_DIR="$AGENTS_ROOT/tools"
GA_TEMPLATE="$TOOL_DIR/google-analytics.md.template"
GA_OUT="$SKILLS_DIR/google-analytics/SKILL.md"

TOOL_VERSION="0.1.0"
PROG_NAME="$(basename "${BASH_SOURCE[0]}")"

# Scopes the GA MCP needs: analytics read + cloud-platform (for the quota project).
GA_SCOPES="https://www.googleapis.com/auth/analytics.readonly,https://www.googleapis.com/auth/cloud-platform"
GA_APIS="analyticsadmin.googleapis.com analyticsdata.googleapis.com"

die() {
  echo "error: $*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing required command: $1 (install or add to PATH)"
}

bar() { printf '%*s' 68 '' | tr ' ' '='; }

print_intro() {
  local b; b="$(bar)"
  echo "$b"
  echo "  $PROG_NAME · Byrde Agents  v$TOOL_VERSION"
  echo ""
  echo "  Pin a GA4 property and install the google-analytics skill."
  echo "  Registers Google's analytics-mcp server (read-only reporting)."
  echo ""
  printf '  %-16s %s\n' "Context Root" "$WORKSPACE_ROOT"
  printf '  %-16s %s\n' "Layout" "$(layout_describe)"
  echo "$b"
  echo ""
}

pick_from_menu() {
  local title="$1"; shift
  local -a choices=("$@")
  [[ ${#choices[@]} -gt 0 ]] || die "no options for: $title"
  echo "" >&2; echo "  $title" >&2
  local i=1 c
  for c in "${choices[@]}"; do echo "    $i) $c" >&2; ((i++)) || true; done
  local sel
  while true; do
    read -r -p "  Enter number (1-${#choices[@]}): " sel || die "stdin closed"
    if [[ "$sel" =~ ^[0-9]+$ ]] && ((sel >= 1 && sel <= ${#choices[@]})); then
      echo "${choices[$((sel - 1))]}"; return 0
    fi
    echo "  Invalid choice." >&2
  done
}

# ─── gcloud identity / ADC ──────────────────────────────────────────────────

list_gcloud_accounts() {
  gcloud auth list --format="value(account)" 2>/dev/null | sort -f || true
}

active_gcloud_account() {
  gcloud auth list --filter="status:ACTIVE" --format="value(account)" 2>/dev/null | head -n1 || true
}

# Does the well-known ADC file already exist? (presence only — scopes are
# validated at first MCP call, gcloud doesn't expose ADC scopes for inspection.)
adc_present() {
  local adc="${GOOGLE_APPLICATION_CREDENTIALS:-}"
  [[ -n "$adc" && -f "$adc" ]] && return 0
  [[ -f "$HOME/.config/gcloud/application_default_credentials.json" ]]
}

# Establish ADC for the analytics scope. Google blocks its SHARED gcloud OAuth
# client for analytics.readonly, so a plain login no longer works — the user must
# supply their OWN OAuth client (Desktop app). --client-id-file is required here,
# not optional.
run_adc_login() {
  local client_file="$1"
  echo "" >&2
  echo "── Application Default Credentials ──" >&2
  echo "  Scopes: $GA_SCOPES" >&2
  gcloud auth application-default login --scopes "$GA_SCOPES" --client-id-file="$client_file"
}

# Prompt (looping) for a readable OAuth client JSON. Required — Google rejects its
# shared client for the analytics scope. $1 = GCP project, used only to make the
# console links project-scoped.
prompt_client_json() {
  local project="$1" path
  echo "" >&2
  echo "  Google blocks its shared OAuth client for the analytics.readonly scope," >&2
  echo "  so ADC needs your OWN OAuth client (Desktop app). If the project sits in" >&2
  echo "  a Workspace org, an Internal consent screen needs no Google verification:" >&2
  echo "    1. Consent screen → Internal:" >&2
  echo "       https://console.cloud.google.com/auth/audience?project=$project" >&2
  echo "    2. Create an OAuth client (Desktop app), then download its JSON:" >&2
  echo "       https://console.cloud.google.com/apis/credentials?project=$project" >&2
  while true; do
    read -r -p "  Path to your OAuth client JSON: " path || die "stdin closed"
    path="${path/#\~/$HOME}"
    [[ -n "$path" ]] || { echo "  A client JSON is required for the analytics scope." >&2; continue; }
    [[ -f "$path" ]] || { echo "  Not found: $path" >&2; continue; }
    echo "$path"; return 0
  done
}

ensure_adc() {
  local project="$1"
  if adc_present; then
    local ans
    read -r -p "  ADC already present. Re-run the login to (re)grant the analytics scope? [y/N] " ans
    [[ "${ans:-n}" =~ ^[Yy]$ ]] || { echo "  ✓ keeping existing ADC."; return 0; }
  else
    echo "  No Application Default Credentials found — a login is required."
  fi
  local client_file
  client_file="$(prompt_client_json "$project")"
  if run_adc_login "$client_file"; then
    echo "  ✓ ADC established."
  else
    echo "" >&2
    echo "  ADC login failed. If Google still blocked the scope, confirm the consent" >&2
    echo "  screen is set to Internal and you signed in with an account in that org," >&2
    echo "  then re-run this script." >&2
    die "could not establish Application Default Credentials"
  fi
}

prompt_gcp_project() {
  local default sel
  default="$(gcloud config get-value project 2>/dev/null | grep -v '^(unset)$' || true)"
  while true; do
    echo "" >&2
    if [[ -n "$default" ]]; then
      read -r -p "  Google Cloud project ID for GA quota/billing [$default]: " sel
      sel="${sel:-$default}"
    else
      read -r -p "  Google Cloud project ID for GA quota/billing: " sel
    fi
    [[ -n "$sel" ]] || { echo "  Project ID cannot be empty." >&2; continue; }
    echo "$sel"; return 0
  done
}

offer_enable_apis() {
  local project="$1" ans
  echo "" >&2
  echo "  GA MCP needs these APIs enabled on $project:" >&2
  echo "    $GA_APIS" >&2
  read -r -p "  Enable them now via gcloud? [Y/n] " ans
  if [[ "${ans:-y}" =~ ^[Yy]$|^$ ]]; then
    # shellcheck disable=SC2086
    if gcloud services enable $GA_APIS --project "$project"; then
      echo "  ✓ APIs enabled."
    else
      echo "  ⚠ Could not enable APIs (insufficient permission?). Enable them manually:" >&2
      echo "    https://support.google.com/googleapi/answer/6158841" >&2
    fi
  else
    echo "  Skipped — enable them before first use:" >&2
    echo "    gcloud services enable $GA_APIS --project $project" >&2
  fi
}

# GA4 property is pinned at runtime only (no default). Numeric property id — NOT
# the G-XXXX measurement id. Blank input is allowed so install can proceed before
# the property is known; the skill renders a "not yet pinned" note in that case.
prompt_property_id() {
  local sel
  echo "" >&2
  echo "  GA4 property ID is the NUMERIC id (e.g. 123456789), not the G-XXXX" >&2
  echo "  measurement id. Find it in GA Admin → Property Settings." >&2
  read -r -p "  GA4 property ID (Enter to skip and pin later): " sel
  echo "$sel"
}

# ─── skill render / sync ────────────────────────────────────────────────────

render_skill() {
  local template="$1" out="$2" property="$3" gcp_project="$4"
  [[ -f "$template" ]] || die "missing template: $template"
  mkdir -p "$(dirname "$out")"
  local property_display="$property"
  [[ -n "$property_display" ]] || property_display="(not yet pinned — re-run setup-google-analytics.sh)"
  RENDER_TEMPLATE="$template" RENDER_OUT="$out" \
    RENDER_PROPERTY="$property_display" RENDER_GCP_PROJECT="$gcp_project" \
    python3 <<'PY'
from pathlib import Path
import os
src = Path(os.environ["RENDER_TEMPLATE"]); dst = Path(os.environ["RENDER_OUT"])
out = (src.read_text()
       .replace("{{PROPERTY_ID}}", os.environ["RENDER_PROPERTY"])
       .replace("{{GCP_PROJECT}}", os.environ["RENDER_GCP_PROJECT"]))
dst.write_text(out); print("Wrote", dst)
PY
}

sync_skill_to_editors() {
  local skill="$1"
  local src="$SKILLS_DIR/$skill"
  [[ -d "$src" ]] || return 0
  local dest
  for dest in "$WORKSPACE_ROOT/.claude/skills" "$WORKSPACE_ROOT/.cursor/skills"; do
    mkdir -p "$dest"; rm -rf "${dest:?}/$skill"; cp -R "$src" "$dest/$skill"
    echo "  skills/$skill → ${dest#"$WORKSPACE_ROOT"/}/$skill"
  done
}

# ─── MCP registration (analytics-mcp via pipx; GOOGLE_PROJECT_ID only) ───────

_mcp_merge_ga() {
  local path="$1" project="$2" tmp
  tmp="$(mktemp)"
  mkdir -p "$(dirname "$path")"
  if [[ -f "$path" ]]; then
    jq --arg proj "$project" '
      .mcpServers = (.mcpServers // {}) |
      .mcpServers["analytics-mcp"] = {
        command: "pipx",
        args: ["run", "analytics-mcp"],
        env: { "GOOGLE_PROJECT_ID": $proj }
      }' "$path" >"$tmp" || { rm -f "$tmp"; echo "  ⚠ jq failed on $path — left unchanged" >&2; return 1; }
  else
    jq -n --arg proj "$project" '{
      mcpServers: { "analytics-mcp": {
        command: "pipx", args: ["run", "analytics-mcp"],
        env: { "GOOGLE_PROJECT_ID": $proj } } } }' >"$tmp"
  fi
  mv "$tmp" "$path"
}

mcp_merge_ga() {
  local root="$1" project="$2"
  _mcp_merge_ga "$root/.mcp.json" "$project" && echo "  ✓ .mcp.json — mcpServers[\"analytics-mcp\"]"
  _mcp_merge_ga "$root/.cursor/mcp.json" "$project" && echo "  ✓ .cursor/mcp.json — mcpServers[\"analytics-mcp\"]"
}

_mcp_remove_ga() {
  local path="$1" tmp
  [[ -f "$path" ]] || return 0
  jq -e '.mcpServers["analytics-mcp"]' "$path" >/dev/null 2>&1 || return 0
  tmp="$(mktemp)"
  if jq 'del(.mcpServers["analytics-mcp"])' "$path" >"$tmp" 2>/dev/null; then
    mv "$tmp" "$path"
    echo "  removed mcpServers[\"analytics-mcp\"] from $path"
  else
    rm -f "$tmp"
    echo "  ⚠ jq failed on $path — left unchanged" >&2
  fi
}

mcp_remove_ga() {
  local root="$1"
  _mcp_remove_ga "$root/.mcp.json"
  _mcp_remove_ga "$root/.cursor/mcp.json"
}

# ─── Uninstall ──────────────────────────────────────────────────────────────

uninstall() {
  require_cmd jq
  local b; b="$(bar)"
  echo "$b"
  echo "  $PROG_NAME · Uninstall  v$TOOL_VERSION"
  echo ""
  echo "  Removes the google-analytics skill and the analytics-mcp server."
  echo "  Leaves your gcloud ADC in place — revoke it yourself if you want:"
  echo "    gcloud auth application-default revoke"
  echo "$b"
  echo ""

  rm -rf "$SKILLS_DIR/google-analytics"
  echo "  removed skills/google-analytics"
  local dest
  for dest in "$WORKSPACE_ROOT/.claude/skills/google-analytics" "$WORKSPACE_ROOT/.cursor/skills/google-analytics"; do
    rm -rf "$dest"; echo "  removed ${dest#"$WORKSPACE_ROOT"/}"
  done

  echo ""
  echo "── Removing MCP registration ──"
  mcp_remove_ga "$WORKSPACE_ROOT"

  manifest_remove "google-analytics"
  echo ""
  echo "Done. Restart your editor so it drops the analytics-mcp server."
}

# ─── Main ────────────────────────────────────────────────────────────────────

main() {
  case "${1:-}" in
    -h | --help | help)
      echo "$PROG_NAME · Byrde Agents v$TOOL_VERSION"
      echo ""
      echo "Pins a GA4 property, establishes gcloud ADC, installs the"
      echo "google-analytics skill, and registers the analytics-mcp server."
      echo ""
      echo "Usage:"
      echo "  cd /your/workspace && $0              # configure GA reporting"
      echo "  cd /your/workspace && $0 uninstall    # remove the skill + MCP server"
      exit 0
      ;;
    uninstall | remove)
      uninstall
      exit 0
      ;;
  esac

  require_cmd gcloud
  require_cmd pipx
  require_cmd jq
  require_cmd python3

  print_intro

  # ── Google account ──────────────────────────────────────────────────────────
  local accounts=() line
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -n "$line" ]] && accounts+=("$line")
  done < <(list_gcloud_accounts)
  [[ ${#accounts[@]} -gt 0 ]] || die "no authenticated gcloud accounts — run: gcloud auth login"

  local account
  if [[ ${#accounts[@]} -eq 1 ]]; then
    account="${accounts[0]}"
    echo "  Using Google account: $account"
  else
    local active; active="$(active_gcloud_account)"
    [[ -n "$active" ]] && echo "  Active gcloud account: $active"
    account="$(pick_from_menu "Google accounts (from gcloud auth list):" "${accounts[@]}")"
  fi
  gcloud config set account "$account" >/dev/null 2>&1 || true

  # ── GCP project (quota/billing) ───────────────────────────────────────────
  local gcp_project
  gcp_project="$(prompt_gcp_project)"

  # ── Enable required APIs ──────────────────────────────────────────────────
  offer_enable_apis "$gcp_project"

  # ── Application Default Credentials ───────────────────────────────────────
  ensure_adc "$gcp_project"

  # ── GA4 property to pin ───────────────────────────────────────────────────
  local property_id
  property_id="$(prompt_property_id)"

  # ── Render skill ──────────────────────────────────────────────────────────
  echo ""
  echo "── Installing google-analytics skill ──"
  ignore_skills_home
  render_skill "$GA_TEMPLATE" "$GA_OUT" "$property_id" "$gcp_project"
  sync_skill_to_editors "google-analytics"
  manifest_add "google-analytics"

  # ── Register the analytics-mcp server ─────────────────────────────────────
  echo ""
  echo "── Registering analytics-mcp ──"
  mcp_merge_ga "$WORKSPACE_ROOT" "$gcp_project"
  echo "    auth: Application Default Credentials (gcloud) — no secret in the config;"
  echo "          only GOOGLE_PROJECT_ID=$gcp_project is stored."

  echo ""
  if [[ -n "$property_id" ]]; then
    echo "Done. GA4 property $property_id (quota project $gcp_project)."
  else
    echo "Done. No GA4 property pinned yet — re-run this script to pin one."
  fi
  echo "  Verify with: .agents/scripts/doctor.sh"
  echo "  Restart your editor so it picks up the analytics-mcp server."
}

main "$@"
