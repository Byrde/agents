# root.sh — the project the OpenCode scripts install into.
#
# OpenCode reads its config from the folder it opens, so the scripts install
# where they run: the current folder, or the root of the git repo that holds it.
# resolve_layout puts the workspace root at the parent of the .agents checkout,
# which is the project only when .agents is a submodule there.
#
# Source after lib/layout.sh and lib/workspace.sh. Call after resolve_layout.
use_run_root() {
  WORKSPACE_ROOT="$PROJECT_ROOT"
  WORKSPACE_FILE="$WORKSPACE_ROOT/.workspace.agents.json"
  detect_sibling_repos
  export WORKSPACE_ROOT
}
