#!/usr/bin/env bash
# Byrde Agents — Artificial Analysis benchmark data (shared lib).
#
# The OpenCode installer reads it to score the models for its agents.
#
# The legacy /api/v2/data/llms/models endpoint was retired on 2026-11-04. The
# free replacement is paginated (200 models a page), returns fewer fields, and
# carries only the intelligence index among the scores the scorers use. A Pro
# key can point BYRDE_AA_URL at /api/v2/language/models for the coding and
# agentic indexes too.
#
# Auth: ARTIFICIAL_ANALYSIS_API_KEY goes in on curl's stdin, never on disk and
# never in `ps`. BYRDE_AA_FILE replaces the download (tests, offline runs).
#
# Requires curl and jq.

AA_URL="${BYRDE_AA_URL:-https://artificialanalysis.ai/api/v2/language/models/free}"
AA_MAX_PAGES=20

# Download every page into <out> as {"data": [...]}. Returns 1 when there is no
# key or the API refuses, and leaves <out> as it was.
aa_fetch() {
  local out="$1" tmp page=1 more sep
  if [[ -n "${BYRDE_AA_FILE:-}" ]]; then cp "$BYRDE_AA_FILE" "$out"; return 0; fi
  [[ -n "${ARTIFICIAL_ANALYSIS_API_KEY:-}" ]] || return 1
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/byrde-aa.XXXXXX")"
  case "$AA_URL" in *\?*) sep="&" ;; *) sep="?" ;; esac
  while :; do
    if ! printf 'x-api-key: %s\n' "$ARTIFICIAL_ANALYSIS_API_KEY" \
         | curl -fsS --max-time 120 -H @- "$AA_URL${sep}page=$page" -o "$tmp/$page.json" 2>/dev/null; then
      rm -rf "$tmp"
      echo "  ⚠ the Artificial Analysis API refused the request (check the key, and BYRDE_AA_URL)" >&2
      return 1
    fi
    more="$(jq -r '.pagination.has_more // false' "$tmp/$page.json" 2>/dev/null)"
    [[ "$more" == "true" && "$page" -lt "$AA_MAX_PAGES" ]] || break
    page=$((page + 1))
  done
  if ! jq -s '{data: (map(.data // []) | add)}' "$tmp"/*.json >"$out.tmp" 2>/dev/null; then
    rm -rf "$tmp" "$out.tmp"
    return 1
  fi
  rm -rf "$tmp"
  mv "$out.tmp" "$out"
}
