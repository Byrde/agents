# Workspace — route work to the right repo

This agent context may span more than one repository: a shared `.agents` sits at
the **context root** (the folder you opened in) above one or more repos. Before
acting on any task that touches code, know WHERE the change belongs.

## Read the map first

`.workspace.agents.json` at the context root lists the repos this context covers:

```json
{ "mode": "multi", "repos": [
  { "name": "...", "path": "<rel>", "remote": "...", "owner": "...",
    "stack": ["scala","docker"], "purpose": "<human-written>" } ] }
```

- `path` is relative to the context root — that's where the repo lives.
- `purpose` is the strongest routing signal when present, then `name`/`path`,
  `stack` (e.g. a Scala change → a scala repo), and any endpoint/service/file
  names. A GitHub `owner/name` or URL maps directly via `remote`.
- `mode: mono` → a single repo, so everything goes there. `mode: multi` → several.

If the file is absent, treat this as a single-repo context. If it looks stale (a
repo it lists is gone, or a repo on disk isn't listed), say so and suggest
re-running `.agents/scripts/init.sh` to refresh it.

## Route, then operate in place

1. Match the request to a repo using the map.
2. If two repos plausibly match — or none clearly does — **ask** which, citing the
   candidates. Don't spread a speculative change across repos.
3. Treat the chosen repo's `path` as the working root: search, read, edit, and run
   build/test commands there.
4. Follow THAT repo's own conventions (its `CLAUDE.md`, `.agents`, rules), not the
   workspace root's. For work spanning several repos, handle each as a separate
   unit (separate branches/PRs unless told otherwise) and call out the
   cross-repo coordination.

The map reflects what was true when generated — sanity-check a repo's `path`
still exists before relying on it, and offer to fill in a missing `purpose` when
you learn one.
