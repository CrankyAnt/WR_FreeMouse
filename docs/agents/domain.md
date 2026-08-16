# Domain Documentation

Read the relevant domain documentation before exploring or naming concepts:

- Root `CONTEXT.md` for a single context.
- Root `CONTEXT-MAP.md` for multiple contexts, followed by every linked `CONTEXT.md` relevant to the work.
- Root `docs/adr/` for architectural decisions relevant to the area.

`CONTEXT.md` is a domain-language glossary, not a README, implementation plan, or architecture guide. Use its canonical terms in issues, specs, tests, and code.

Create domain files lazily through `model-domain` when a real term or qualifying decision crystallises. ADRs always go under root `docs/adr/`, including decisions concerning a subcontext.

If ADRs or context documents are found outside the configured layout, report them and propose a maintenance issue. Do not silently move or duplicate them while doing unrelated work. Surface conflicts with an existing ADR explicitly.

## Standalone domain-documentation delivery

This strategy applies only when no invoking workflow already owns the domain change. Domain artifacts created inside a delivery follow that delivery's recorded delivery path and publish boundary.

**Delivery path:** direct-main
**Publish boundary:** commit-and-push
**Required validation:** Verify the configured domain layout, inspect the exact artifact diff, and run `git diff --check`.
**Reason:** Small, reversible canonical-language changes must reach the base branch before dependent specs and branches are created.
