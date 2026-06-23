#!/usr/bin/env bash
# Shared manifest helpers for the Byrde Agents setup scripts.
#
# The manifest records which tool skills are installed in THIS checkout. It is
# gitignored — per-developer / per-checkout state, not submodule content. Each
# setup-*.sh adds its capability keys on install and removes them on uninstall;
# doctor.sh reads it to decide which tools to validate. A tool is "set up" iff
# its key is present here, so an uninstall (which removes the key) makes the
# tool disappear from the doctor report even if leftover files remain on disk.
#
# Capability keys (per-capability granularity):
#   github-source-control  github-projects     google-analytics
#   jira                   figma-design-system figma-design-file
#   figma-use              memory
#
# Format — deliberately simple so it parses with grep/sed (no yq, Bash 3.2 ok):
#
#   installed:
#     - github-source-control
#     - memory
#
# Source this file after SCRIPT_DIR is set, then call manifest_add /
# manifest_remove / manifest_has / manifest_list.

# Resolve the manifest path to <.agents>/.manifest.local.yml (sibling of
# skills/). Honour a pre-set MANIFEST_FILE so tests can point it elsewhere.
_manifest_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST_FILE="${MANIFEST_FILE:-$(cd "$_manifest_lib_dir/../.." && pwd)/.manifest.local.yml}"

# List installed capability keys, one per line (empty when none / no file).
manifest_list() {
  [[ -f "$MANIFEST_FILE" ]] || return 0
  sed -n 's/^[[:space:]]*-[[:space:]]*//p' "$MANIFEST_FILE" 2>/dev/null \
    | grep -v '^[[:space:]]*$' || true
}

# Is a capability key recorded as installed? Returns 0 (true) when present.
manifest_has() {
  manifest_list | grep -qxF "$1"
}

# Rewrite the manifest from a newline-separated key set (internal).
_manifest_rewrite() {
  local keys="$1" tmp
  # The manifest may live in a per-project home (e.g. <repo>/.byrde/ in
  # multi-repo mode) that does not exist yet — ensure its dir before writing.
  mkdir -p "$(dirname "$MANIFEST_FILE")"
  tmp="$(mktemp)"
  {
    echo "# Byrde Agents — tool skills installed in this checkout."
    echo "# Gitignored, per-checkout state. Maintained by scripts/setup-*.sh;"
    echo "# read by scripts/doctor.sh to decide what to validate."
    if [[ -z "$keys" ]]; then
      echo "installed: []"
    else
      echo "installed:"
      # Unquoted on purpose: word-split the newline-separated keys.
      printf '  - %s\n' $keys
    fi
  } >"$tmp"
  mv "$tmp" "$MANIFEST_FILE"
}

# Record a capability key as installed (idempotent).
manifest_add() {
  local key="$1" keys
  keys="$( { manifest_list; echo "$key"; } | sort -u | grep -v '^[[:space:]]*$' || true )"
  _manifest_rewrite "$keys"
}

# Remove a capability key (idempotent — no-op if absent).
manifest_remove() {
  local key="$1" keys
  keys="$( manifest_list | grep -vxF "$key" | sort -u | grep -v '^[[:space:]]*$' || true )"
  _manifest_rewrite "$keys"
}
