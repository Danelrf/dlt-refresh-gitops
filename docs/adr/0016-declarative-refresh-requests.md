# 16. Full refreshes are declared in `refresh-requests.yaml`

Date: 2026-08-01

## Status

Accepted

## Context

A full refresh truncates and recomputes a pipeline's tables. In production this
is destructive and irreversible. It needs to be possible, deliberate, approved by
someone other than the requester, and recorded.

The mechanism also has to sit somewhere. Doing it by hand in the Databricks UI
leaves no reviewable artifact; putting it behind a button in CI makes it too easy.

## Decision

Refreshes are declared as entries in `governance/refresh-requests.yaml`:

```yaml
- pipeline_key: "orders_pipeline"
  release_version: "2.14.0"
  reason: "Upstream schema fix, JIRA-4821"
```

The file is CODEOWNERS-protected, so a platform lead must approve the pull
request and the author cannot self-approve. The release workflow looks for an
entry matching the tag being released; the refresh runs only if it finds exactly
one.

This is the Flyway/Liquibase migration pattern applied to pipeline refreshes: the
requests file plays the role of migration scripts, and the audit issues (ADR
0017) play the role of `flyway_schema_history`.

## Alternatives considered

**Status fields written back by CI** — marking entries `applied: true` after
execution. Rejected because it conflates two different records. The repository
answers "what was approved, by whom, when" through git and pull request history.
Execution outcomes are a separate concern and live in the audit issues. Writing
back also means CI needs write access to the branch it deploys from.

**Calling it a changelog.** Rejected deliberately: a changelog describes the past.
This file describes intent about the future, and the name should say so.

**Guessing when a tag matches more than one entry.** Rejected — two entries for
one tag is a review mistake, and the workflow fails hard rather than picking one.

## Consequences

- Code and refresh intent version together. A release that changes pipeline logic
  *and* requires a refresh is one pull request, one review, one tag. They cannot
  drift apart.
- The refresh is a separate, skippable job. A tag with no matching entry means
  the job never starts, which shows up as a cleanly skipped job rather than a
  silent no-op.
- Entries reference `pipeline_key` — the bundle resource key — not a pipeline
  UUID. The workflow resolves it through `databricks bundle summary`, so there
  are no hardcoded IDs to keep in sync as environments are rebuilt.
- Requests are never removed after execution; the file accumulates. That is
  intentional — it is the declared history of intent.
- The file is not schema-validated on pull requests, so a malformed entry is
  caught at release time rather than at review time. This is a known gap.
- `reason` is author-controlled text that reaches a runner holding production
  credentials, which is why it is passed only as an environment variable and
  never interpolated into a shell string.
