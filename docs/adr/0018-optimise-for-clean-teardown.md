# 18. Optimise for clean teardown

Date: 2026-08-01

## Status

Accepted. Amends [0012](0012-environment-scoped-data-access.md) and
[0013](0013-remote-state-and-bootstrap-script.md).

## Context

Earlier records treated this as a production system and protected it
accordingly. `orders_prd` was created with `force_destroy = false` so that a
`terraform destroy` holding real tables would fail rather than succeed quietly.

That was the wrong optimisation for what this repository actually is: a learning
project, built to be stood up, understood, and deleted. The most important
property of a learning environment is that it goes away completely — leftover
Azure resources cost money, and leftover Entra applications and GitHub
Environments are clutter in a personal tenant.

A second problem surfaced while writing the teardown path. `terraform destroy`
cannot remove everything, because `bootstrap.sh` deliberately creates resources
that no Terraform state knows about: the state storage account, the Entra
application, its subscription role assignments, and the GitHub Environments.
They exist precisely because they had to precede Terraform. Nothing was going to
clean them up.

## Decision

Two changes:

1. A single `force_destroy` variable, defaulting to `true`, applied to catalogs,
   external locations and the storage credential. It replaces the per-environment
   `catalog_force_destroy` flag, which no longer earns its complexity.
2. `infra/teardown.sh`, which destroys both Terraform stages in reverse order and
   then removes the bootstrap-created resources Terraform never saw.

## Alternatives considered

**Keep `force_destroy = false` on prd and delete it by hand when finished.**
Rejected: "by hand" for a Unity Catalog catalog containing managed tables means
finding and dropping each object first. That is exactly the friction the
protection is designed to create, and here it protects nothing worth protecting.

**Leave teardown to `terraform destroy` and document the manual remainder.**
Rejected. A documented manual cleanup list is a list that will be followed
incompletely, and the residue is the expensive kind — a storage account and an
Entra application with subscription-scoped role assignments.

## Consequences

- `terraform destroy` on prd now succeeds and discards data without complaint.
  **For anything real, set `force_destroy = false`.** The safety this gives up is
  precisely the safety you want when the data matters.
- The per-environment access model (ADR 0012) is unchanged; only the destroy
  guardrail moved out of it and became global.
- `teardown.sh` deletes the state account last, since destroying the
  Terraform-managed resources requires the state to still exist.
- It requires typing the project name to confirm — enough friction to prevent an
  accident, not enough to be an obstacle.
- Two residues remain by design and are printed at the end: soft-deleted Entra
  applications are recoverable for 30 days, and the Databricks account itself
  survives, because it is tied to the Entra tenant rather than to any workspace.
