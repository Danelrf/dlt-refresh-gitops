# 9. Databricks-managed service principals for the deploy identities

Date: 2026-08-01

## Status

Accepted

## Context

The `tst` and `prd` deploy identities could be either Microsoft Entra ID service
principals registered into Databricks, or service principals that exist only in
the Databricks account. Both work with OIDC federation (ADR 0008) — the
federation policy attaches to a Databricks service principal by numeric ID
regardless of which kind it is — so this was a genuine choice rather than
something the auth mechanism forced.

The question is what these identities actually need to do. They run
`databricks bundle deploy` and `databricks bundle run --full-refresh-all`, they
own their catalog, and they are the `run_as` principal for the pipeline. They
never call an Azure API: storage is reached through the Access Connector's
managed identity, not through them.

## Decision

`sp-<project>-tst` and `sp-<project>-prd` are Databricks-managed service
principals. The Terraform runner remains an Entra service principal, because it
genuinely does need Azure RBAC.

## Alternatives considered

**Entra ID for all three identities.** The argument is centralised governance:
Conditional Access, PIM, access reviews and joiner/mover/leaver processes cover
every non-human identity uniformly, and Entra sign-in logs capture their use. A
Databricks-managed principal is invisible to all of that. Many organisations
mandate this, and if a client does, it overrides what we chose here.

Rejected for this project on least-privilege grounds, with a decisive
second-order effect: **if Terraform creates Entra applications, the Terraform
runner must hold directory write permission** (`Application.ReadWrite.OwnedBy` or
equivalent). That lets a CI runner mint identities in the tenant. Avoiding it
confines the runner's privileges to a single subscription.

**Entra identities created by `bootstrap.sh` rather than by Terraform.** Keeps
them in Entra's governance plane while still denying the runner directory write
permission. Rejected because it makes adding an environment a manual step,
undoing part of ADR 0007.

## Consequences

- The deploy identities cannot be granted Azure permissions, even by mistake.
  Their blast radius is bounded by Databricks.
- The `azuread` provider is no longer needed in `infra/databricks/` at all; only
  `bootstrap.sh` touches Entra.
- These identities do not appear in Entra access reviews. Offboarding and
  auditing for them happens in the Databricks account console instead, which is a
  second place to look and a real cost.
- If a deploy identity ever needs to read a Key Vault or call an Azure API, this
  decision must be revisited. Reversing it is contained: add an
  `azuread_application` and pass its `client_id` to `databricks_service_principal`.
  The federation policy and both workflows stay byte-identical.
- Creating account-level principals requires the Terraform runner to be a
  Databricks **account admin** — a manual grant, and the main friction in
  `bootstrap.sh`.
