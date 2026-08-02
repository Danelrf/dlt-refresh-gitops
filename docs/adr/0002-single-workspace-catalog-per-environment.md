# 2. One workspace, one catalog per environment

Date: 2026-08-01

## Status

Accepted

## Context

The repo defines three environments — `dev`, `tst` and `prd`. They needed a
physical home in Azure. The choice was how much of the stack to duplicate per
environment, which trades cost and operational weight against how strong the
isolation between environments is.

## Decision

One Azure Databricks workspace. Each environment is a separate Unity Catalog
catalog (`orders_dev`, `orders_tst`, `orders_prd`), backed by its own storage
container, with its own service principal and its own grants.

## Alternatives considered

**Two workspaces, one for tst and one for prd.** The strongest isolation: separate
control planes, separate hosts, no possibility of a misconfigured grant reaching
across environments. Rejected on cost and setup weight for a project of this
size. It also would not have bought as much as it appears to, because the
isolation that actually matters here — who can authenticate as what — is enforced
by federation policy subjects (ADR 0011), which are per-environment regardless of
how many workspaces exist.

**Reusing an existing workspace** already present on the machine
(`adb-8952405997873616`). Least new infrastructure. Rejected because its Unity
Catalog state was unknown and it belonged to an unrelated tenant, so building on
it would have coupled this project to something outside its control.

## Consequences

- tst and prd share a workspace URL. The earlier README claimed the two "never
  share credentials"; with one host that statement had to become narrower and
  more accurate — they share a host and share nothing else. ADR 0008 and ADR 0011
  are what make that acceptable, because there are no credentials to share.
- Isolation is enforced at the catalog and grant layer. A mistake in
  `databricks/variables.tf` could in principle expose one environment to another,
  where two workspaces would have made that structurally impossible. This is the
  real cost of the decision, and it is why the access model is expressed as
  reviewable data in one place (ADR 0012).
- Storage is one ADLS Gen2 account with one container per environment, so data
  at rest still has a per-environment boundary and a per-environment external
  location.
- Adding a fourth environment is a map entry in `databricks/variables.tf` plus a
  target in `databricks.yml`, not a new workspace.
- Workspace SKU must be `premium`: Unity Catalog, pipeline ACLs and service
  principal permissions are all premium-tier features, and the entire governance
  model depends on them.
