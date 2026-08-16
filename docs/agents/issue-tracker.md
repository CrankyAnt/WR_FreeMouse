# Issue Tracker: GitHub

Issues, specs, Work Briefs, maps, and tickets live in GitHub Issues. Repository visibility and shared-surface publication policy are recorded in `docs/agents/publication.md`; delivery path, publish boundary, and validation policy are recorded in `docs/agents/delivery.md`.

## Tool routing

Use local Git for status, diff, branches, staging, commits, and pushes. Use the active purpose-built GitHub integration first for issues, comments, labels, sub-issues, dependencies, pull requests, and merges. Use `gh` only when the integration is unavailable or lacks the required operation, and report the fallback. Use the normal credential store; never copy tokens into prompts, environment variables, or plaintext configuration.

## Request surface

**External pull requests are a request surface:** `yes`

When enabled, triage external contributor PRs through the same semantic labels as issues. Leave owner, member, and collaborator work out of discovery unless explicitly named.

## Semantic operations

- Publish a spec, Work Brief, ticket, map, or resolution as the corresponding GitHub issue or comment.
- Apply labels using `docs/agents/triage-labels.md`.
- Use one `planning:map` issue with child issues labelled by planning type.
- Use native sub-issues and issue dependencies. If the purpose-built integration lacks a required relationship operation, use `gh`; add body relationship fallbacks only when GitHub itself lacks the native relationship.
- Claim a planning ticket by assigning it to the driving developer before work.
- The frontier is the ordered set of open, unblocked, unassigned children.
- Resolve with a professional evidence-based comment, close the child, and append only a gist and link to the map's decision index.

GitHub issue history is durable. Do not create a duplicate Markdown document for each GitHub issue.
