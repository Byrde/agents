---
name: shipping-size
description: Small fixes and docs go straight to main; large multi-part changes go one PR per unit on its own branch
metadata:
  node_type: memory
  type: feedback
  originSessionId: f049ab7e-03d1-41c8-a19c-6f9ca0716bc0
  modified: 2026-10-28T18:03:30.636Z
---

Small fixes and doc edits in Byrde/agents go straight to main when the user says so ("Pushed right to main", "fix it right to main"). A large change split into units gets one branch and one pull request per unit ("Just create a branch each unit is a PR", 2026-10-28, for the move from MCP servers to CLIs).

**Why:** The user wants to review a large change, such as new rule wording that agents will follow, before it lands. Small edits do not need that.

**How to apply:** Ask, or follow what the user said for this change. Never carry "push to main" from one change to the next. See also [[mcp-to-cli]].
