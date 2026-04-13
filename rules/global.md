# Project Grounding

If a `README.md` exists at the project root, read it at the start of every conversation before doing any work. The README is the source of truth for what this project is, how it is organised, and what conventions it follows. Do not assume you already know the project — re-read it each session.

# Memory Bank

If a `.mempalace/` directory exists at the project root and a `mempalace` MCP server is available, you have access to persistent memory across conversations.

At the start of each conversation, **search** mempalace for prior context relevant to the current task — past decisions, architectural notes, user preferences, and domain knowledge that may have been captured in earlier sessions.

Memory **saving is handled automatically by hooks**. Do **not** write to mempalace directly through MCP tools. Treat it as read-only.

If `.mempalace/` does not exist or the MCP server is not configured, ignore this section entirely.
