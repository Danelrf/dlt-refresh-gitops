# 15. Trunk-based branching: `main` deploys tst, `v*` tags deploy prd

Date: 2026-08-01

## Status

Accepted

## Context

The project needed a branching model and a mapping from git events to
deployments. Three environments exist, but only two are CI-deployed: `dev` is
deployed by engineers from their own machines (ADR 0012), so only `tst` and `prd`
need a trigger.

An earlier iteration had two separate workflows, `deploy-tst.yml` and
`release.yml`, one per environment.

## Decision

Trunk-based. One long-lived branch, `main`. Work happens in short-lived branches
and lands by pull request.

- Merge to `main` → unit tests → deploy to `tst`.
- Tag `X.Y.Z` → unit tests → deploy to `tst` → deploy to `prd` → optional
  gated refresh.

Release tags are bare semver with no `v` prefix, matched by the filter pattern
`[0-9]+.[0-9]+.[0-9]+` so that only well-formed release tags trigger a
deployment.

Both paths live in a single `deploy.yml` under one `concurrency` group.

## Alternatives considered

**Separate workflows per environment**, the prior arrangement. Rejected for two
reasons. A merge to `main` and a tag push could race on the tst target, since
nothing serialised them. And with prd releasing from its own workflow, tst could
silently drift behind a release that appeared to touch only prd.

**A `workflow_dispatch` path** for ad-hoc deploys or refreshes. Rejected as a
parallel, ungoverned route to production. Releases here are on-demand anyway, so
the pull request path is already fast enough for urgent work. The break-glass
procedure for "the release pipeline itself is broken" is to run
`databricks bundle run <key> --target prd --full-refresh-all` manually and file
the audit issue retroactively — a deliberately uncomfortable path that leaves a
trace.

## Consequences

- **Tagging a release re-deploys tst before prd.** `deploy-prd` depends on
  `deploy-tst` within the same run, so every release re-validates and re-syncs
  tst first. This is a safety net that catches a bad bundle before it reaches
  prd, and it guarantees tst is never behind prd.
- A single `concurrency: group: deploy` serialises everything, so the race that
  motivated the merge is structurally gone rather than merely unlikely.
- Release versioning is carried by git tags, which is what
  `refresh-requests.yaml` keys against (ADR 0016). Tag and refresh intent cannot
  drift because they are the same identifier.
- Unit tests gate every path, including releases. A tag on a commit whose tests
  fail deploys nothing.
- There is no release branch, so a hotfix to production is a commit on `main`
  plus a new tag. For a project of this size that is the right trade; a team
  needing to patch an old release without shipping newer `main` commits would
  have to revisit this.
- `prd` deploys only from `refs/tags/`, checked in the job condition, so a
  branch push cannot reach production even if the workflow were triggered. The
  trigger's tag pattern already guarantees the shape, so the condition only has
  to distinguish tags from branches.
