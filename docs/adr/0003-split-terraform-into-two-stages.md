# 3. Split Terraform into platform and databricks stages

Date: 2026-08-01

## Status

Accepted

## Context

The configuration started as a single root module holding both the Azure
resources and the Databricks resources. The `databricks` provider was configured
from an attribute of a resource in the same module:

```hcl
provider "databricks" {
  host                        = "https://${azurerm_databricks_workspace.this.workspace_url}"
  azure_workspace_resource_id = azurerm_databricks_workspace.this.id
}
```

Two problems surfaced once the identity model was settled.

## Decision

Two root modules, applied in order:

- `infra/platform/` — `azurerm` only: resource group, workspace, ADLS Gen2
  account and containers, Access Connector and its role assignment.
- `infra/databricks/` — `databricks` only: account service principals, federation
  policies, workspace assignment, group, catalogs, external locations, grants.

Stage 2 reads stage 1's outputs through `terraform_remote_state`. Each has its
own state key in the same backend.

## Alternatives considered

**A single root module**, with the first apply run as
`terraform apply -target=azurerm_databricks_workspace.this` followed by a full
apply. This is the conventional workaround and it does work. Rejected because it
makes every fresh environment — and every state rebuild — depend on an operator
remembering an undocumented two-command sequence. Once ADR 0007 moved applies
into CI, "remember to run a targeted apply first" stopped being expressible at
all: a workflow either applies or it does not.

## Consequences

The split is forced, not stylistic. Two independent reasons:

1. **The Databricks account does not exist until a workspace does.** Its account
   ID is an input to the account-level provider (`accounts.azuredatabricks.net`),
   and it is only obtainable after the first workspace exists. Account-level
   resources therefore cannot be planned in the same apply that creates the
   workspace they depend on. This is not a Terraform limitation; it is the order
   of events in Azure Databricks.
2. **A provider configured from an unknown value is fragile.** Terraform defers
   provider configuration where it can, but the behaviour is not guaranteed
   across resource types and provider versions. Separate states remove the class
   of problem rather than documenting a workaround for it.

Other effects:

- The apply job in `terraform.yml` runs the two stages sequentially in one job,
  so ordering is enforced by the workflow rather than by convention.
- On a brand-new setup, `terraform plan` for stage 2 has nothing to read until
  stage 1 has been applied once. The plan job reports this rather than failing
  mysteriously.
- Renaming a resource in `platform/` propagates through its outputs, so the
  coupling between the stages is explicit and typed rather than duplicated
  string literals.
- Two state files means two lease points, so a stuck lock affects one stage only.
