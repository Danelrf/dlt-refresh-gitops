# 1. Provision infrastructure with Terraform

Date: 2026-08-01

## Status

Accepted

## Context

The repository already governed pipeline code and full-refresh intent through
version control and pull requests, but the Azure and Databricks substrate those
pipelines ran on did not exist yet. Something had to create the workspace,
storage, catalogs and identities.

Whatever we chose would set the tone for the rest of the project: this repo's
central claim is that destructive actions should be declared, reviewed and
executed by machines, not typed by hand. A provisioning mechanism that
contradicted that claim would undermine it.

## Decision

Provision everything with Terraform, in an `infra/` directory inside this same
repository.

## Alternatives considered

**An imperative setup script** using `az` and the `databricks` CLI, written to be
idempotent. Faster to a working workspace, no state file to manage, and no
provider version constraints. Rejected because drift is invisible: a script tells
you what it does when it runs, not what currently exists. There is no plan step,
so no way to review a change before it happens — which is precisely the property
the rest of the repo insists on.

**Terraform plus a one-shot script** for the parts Terraform handles awkwardly,
originally imagined as identity creation and pushing credentials into GitHub.
This turned out to be the shape we arrived at anyway, but for a narrower reason
than anticipated (see ADR 0013): the bootstrap script exists only because a state
backend cannot create itself, not because Terraform is bad at identities.

## Consequences

- Infrastructure changes become reviewable diffs with a machine-generated plan
  attached, which is what made ADR 0007 (apply from CI) possible at all.
- We inherited Terraform's state problem, and with it the need for a remote
  backend and the bootstrap chicken-and-egg described in ADR 0013.
- Terraform on this machine was 1.3.0, released 2022; `azurerm` 4.x requires
  1.9+. We upgraded to 1.15.8 rather than pinning to an old provider line, which
  would have cost us `storage_account_id` on containers and other current
  arguments.
- Provider versions are pinned in `.terraform.lock.hcl`, which is committed, so
  CI and laptops resolve identically.
- Terraform is BUSL-licensed from 1.6 onward. For this project that is
  immaterial; a consultancy redistributing this pattern to clients should
  confirm it is comfortable with that, or substitute OpenTofu, which the
  configuration would accept with no changes.
