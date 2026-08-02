# 13. Remote Terraform state in Azure Blob, created by a bootstrap script

Date: 2026-08-01

## Status

Accepted. [ADR 0018](0018-optimise-for-clean-teardown.md) adds the teardown path
for the resources this record creates outside Terraform.

## Context

Terraform needs somewhere to keep state. Once applies moved into CI (ADR 0007),
local state stopped being an option outright: a runner is ephemeral, and two
stages plus multiple runs must share one view of what exists.

State is also sensitive. Even after ADR 0008 removed client secrets from the
design, state remains the only record of what was created — losing it means
losing the ability to manage or cleanly destroy the estate.

This creates an obvious circularity: the backend cannot be created by the thing
that needs the backend.

## Decision

State lives in an Azure Storage account with one blob per stage
(`platform.tfstate`, `databricks.tfstate`).

`infra/bootstrap.sh` creates that account, plus the Terraform runner service
principal, its GitHub federated credentials, its Azure role assignments, and the
`infra` GitHub Environment. It is the only thing anyone runs by hand.

## Alternatives considered

**Local state**, kept simple for a personal project. Rejected outright once
applies moved to CI — an ephemeral runner has nowhere to keep it.

**Making the backend itself Terraform-managed** in a separate root module.
Rejected: it moves the circularity rather than removing it, since that module
would itself need a backend, and the payoff is small for a resource that is
created once and never changes.

## Consequences

- The script is idempotent by construction. The storage account name is derived
  from a hash of the subscription ID, so re-running converges on the same account
  instead of creating a second one. Every other step checks for existence first.
- Blob versioning and 30-day soft delete are enabled. State is the one artifact
  where an accidental overwrite must be recoverable.
- `--allow-shared-key-access false`: data-plane access is Entra-based only, so
  there is no account key to leak. This is why the script must also grant the
  operator `Storage Blob Data Contributor` explicitly — subscription Owner does
  not confer data-plane access — and why it retries container creation while that
  role assignment propagates.
- Backend configuration is supplied at `init` time
  (`-backend-config=../backend.platform.tfbackend`) rather than hardcoded,
  because the storage account name is not known until the script has run.
- Two things the script deliberately does not do, because both grant
  account-level authority and require a human who already holds it: registering
  the runner as a Databricks account admin, and recording the Databricks account
  ID. It prints both as explicit next steps.
- There is an ordering wrinkle on a fresh tenant: the Databricks account does not
  exist until the first workspace does, so stage 1 must be applied before the
  account admin grant is possible. The script says so.
