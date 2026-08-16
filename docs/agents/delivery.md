# Delivery

## Repository default

Ordinary implementation work uses:

**Delivery path:** dedicated-branch
**Publish boundary:** merge
**Required validation:** narrowest relevant check first (focused test, lint, or targeted runtime check), broadened in proportion to risk; run the repository's normal completion suite before publication once one exists.
**Reason:** Public repository accepting external contributions; branch isolation keeps `main` releasable and matches the global main-branch policy. A small, local, reversible change with no schema, data, dependency, security, authentication, public-API, or parallel-work risk may still use direct-main.

## Work Brief record

Every implementation Work Brief, spec, or delivery ticket records:

```markdown
## Delivery strategy

**Delivery path:** direct-main | dedicated-branch
**Publish boundary:** commit | commit-and-push | draft-pr | merge
**Required validation:** <commands or policy>
**Reason:** <risk-based reason>
```

Use direct-main only for a small, local, reversible change with no schema, data, dependency, security, authentication, public-API, or parallel-work risk, after relevant validation passes and when repository rules permit it. Otherwise use a dedicated branch.

Planning tickets inherit the invoking map's delivery strategy, or this repository strategy when the map records no override. Their durable research artifacts follow the same strategy. Apply an unambiguous direct-main exception autonomously; ask only when the applicable strategy genuinely cannot be determined.

Recommend `merge` for ordinary dedicated-branch delivery. It is evidence-gated: `deliver-work` attempts every acceptance check it can perform, including browser-based visual and interactive workflows, and merges automatically only when every criterion is checked and all review, validation, CI, and mergeability gates pass. Any criterion lacking evidence leaves the PR as draft for the remaining human input. Use `draft-pr` only when preliminary maintainer review is intentionally required even if all criteria can be proven.
