# 11. GitHub Environments are the identity boundary

Date: 2026-08-01

## Status

Accepted

## Context

A federation policy accepts tokens matching one exact subject. GitHub's OIDC
token encodes different things in its `sub` claim depending on what triggered the
run: a branch (`repo:owner/name:ref:refs/heads/main`), a tag, a pull request, or
a deployment environment (`repo:owner/name:environment:prd`).

Choosing which of these to bind to decides what actually separates tst from prd,
given that both live in one workspace (ADR 0002).

## Decision

Bind each deploy identity to a GitHub Environment:

```
sp-<project>-tst   →   repo:<owner>/<repo>:environment:tst
sp-<project>-prd   →   repo:<owner>/<repo>:environment:prd
```

Jobs declare `environment: tst` or `environment: prd`, which is what causes
GitHub to mint a token with the matching subject.

The Terraform runner uses two Entra federated credentials on the same principle:
`environment:infra` for apply, `pull_request` for plan.

## Alternatives considered

**Branch-scoped subjects** (`ref:refs/heads/main`), which is GitHub's default
entity type and the first option Databricks presents. Rejected because branches
and environments are not the same axis. Both the tst deploy and the prd deploy
run from `main` — a merge deploys tst, and a tag on the same commit deploys prd —
so a branch-scoped subject could not distinguish them. It would also mean any
job on `main` could obtain prd credentials, including a job added in a future
pull request. Databricks' own documentation recommends environments over
branches.

## Consequences

- The environment declaration is not merely where configuration lives; it is the
  identity boundary. A job without `environment: prd` cannot authenticate as the
  prd principal — not because it is refused, but because the token it is able to
  mint carries the wrong subject.
- GitHub Environment protection rules therefore become an authentication control,
  not just a deployment gate. Required reviewers on `prd` mean a human must
  approve before the runner can obtain prd credentials at all.
- Environments must be created before the first deploy, which
  `push-github-config.sh` does idempotently. A `PUT` on an existing environment
  leaves its protection rules untouched, so re-running never weakens a gate.
- The `plan` job in `terraform.yml` cannot bind to an environment, because
  `pull_request` runs are not deployments. It uses the separate `pull_request`
  federated credential, which is why plan and apply are distinct trust
  relationships and why apply can be gated independently (ADR 0007).
- Renaming a GitHub Environment silently breaks authentication until the
  federation policy is updated. Both live in Terraform, so the rename is at least
  a visible diff.
- The environment names in `databricks.yml`, the federation policy subjects and
  the workflow job `environment:` keys must agree exactly. They are all derived
  from the same `environments` map in `databricks/variables.tf`.
