# Tool: GitHub

This file defines the GitHub integration context and conventions for all workflows. If this file does not exist or is missing required fields, any workflow that depends on it **must fail immediately** with a clear error explaining what is missing.

## Required Fields

**Account:** <!-- The GitHub account or organization (e.g. byrde) -->
**Repository:** <!-- The GitHub repository (e.g. byrde/my-app) -->
**Project:** <!-- The GitHub Project board name (e.g. My App) -->

## Conventions

### Project Board
If a GitHub Project board does not exist for the repository, create one using the exact same name as the repository. All work items must be tracked against this board.

### Labels
* `Type: Feature` — for feature work items.
* `Type: Bug` — for bug work items.

### Milestones
Epics are represented as GitHub Milestones. All subordinate feature and bug issues are associated with their parent milestone.

### Branch Naming
* `feature/{ISSUE_NUMBER}` — for features and chores that behave like features.
* `bugfix/{ISSUE_NUMBER}` — for bug fixes.
* `patch/{small-slug}` — for small patch work with no backing issue. `{small-slug}` is a short kebab-case descriptor.

### Issue Lifecycle
* Move to **In Progress** when active implementation starts.
* Move to **Ready to Test** when implementation is complete and a PR is open.
* Move to **Done** when QA passes and the PR is merged.

### Pull Requests
Every PR must include a robust body containing:
* Summary of changes.
* How the changes satisfy the acceptance criteria.
* Test evidence.
* Risks or follow-ups.
* A link to the backing issue (`Fixes #123` or equivalent), except for patch work.

When implementation is complete:
* Open the PR with the above body.
* Comment on the backing issue with what was done, the PR link, and anything the tester or reviewer should know.
