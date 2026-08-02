# 7. Apply infrastructure from CI, not from laptops

Date: 2026-08-01

## Status

Accepted

## Context

The Terraform was originally written to be run locally: `terraform apply` from
the `infra/` directory, authenticated by the operator's `az` CLI session, with
the operator's own subscription Owner rights.

This was challenged during review with a direct question: should infrastructure
be provisioned locally at all?

It should not, and the reasons are the same ones the rest of this repo already
argues for pipeline refreshes. Local applies mean the state of production depends
on who ran what and when, there is no plan to review before the change happens,
there is no audit trail beyond shell history, and the identity that created
production is a named human with broad standing privileges.

Gating pipeline refreshes behind review while provisioning the workspace by hand
would have been incoherent.

## Decision

`.github/workflows/terraform.yml` plans on every pull request touching
`infra/**`, and applies on merge to `main`. The apply job binds to the `infra`
GitHub Environment, which can carry required reviewers.

A single local step remains: `infra/bootstrap.sh`, run once.

## Alternatives considered

**Keep Terraform as a local-apply tool** and move it into CI later. This was
offered explicitly as the fast path to a standing workspace. Rejected: the
migration cost is not lower later, and in the interim every applied change would
have been unreviewed.

## Consequences

- A bootstrap remains unavoidable and we stopped pretending otherwise. Something
  must create the first identity CI authenticates as, and the state backend it
  writes to. The goal became making that step minimal, idempotent and documented
  rather than eliminating it (ADR 0013).
- Plans appear in the pull request job summary, so an infrastructure change is
  reviewed as a diff *and* as its effect.
- `concurrency: group: terraform` serialises applies; two at once would fight
  over the state blob lease and one would fail.
- **Anyone who can open a pull request can execute `terraform plan` as the runner
  identity.** Plan is read-only with respect to infrastructure, but it does run
  provider code with the runner's credentials. This is why the runner is scoped
  to a single subscription, and why apply is separately gated by the `infra`
  environment. On a public repository this deserves required reviewers on that
  environment.
- Pull requests from forks cannot plan: GitHub withholds `id-token` from
  forked-repo workflows, so the OIDC exchange in ADR 0008 fails. Expected and
  acceptable for a repo with a small, trusted contributor set.
- The runner needs `Contributor` **and** `Role Based Access Control
  Administrator` at subscription scope, because `platform/main.tf` creates a role
  assignment (Access Connector to storage). That is a broad grant; narrowing it
  to the resource group is the obvious hardening step for a client setting.
