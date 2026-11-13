---
name: mcp-to-cli
description: "The project drops MCP servers for CLIs (gh, acli, curl + gcloud); Figma is the one MCP exception"
metadata:
  node_type: memory
  type: project
  originSessionId: f049ab7e-03d1-41c8-a19c-6f9ca0716bc0
  modified: 2026-10-28T18:03:34.351Z
---

On 2026-10-28 the user decided to drop MCP servers and use CLIs only. GitHub uses `gh` through a wrapper that keeps the workspace's GitHub account. Jira uses Atlassian `acli`. Google Analytics uses `curl` to the GA4 Data API with a gcloud ADC token. Figma stays on MCP.

**Why:** The user wants CLIs exclusively. Figma is the exception because no CLI can create or edit a design. The REST API only reads.

**How to apply:** Do not add a new MCP server. Keep the generic MCP adapters in `scripts/lib/harness.sh` and `scripts/lib/mcp.sh` only for Figma. Workspace trust stays, because Claude Code ignores `.claude/settings.json` (the hooks too) in an untrusted workspace. It is not only an MCP need. See also [[shipping-size]].
