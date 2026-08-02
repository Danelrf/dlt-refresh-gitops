# Unity Catalog: one catalog per environment, backed by that environment's own
# storage container, plus the grants that decide who may do what in each.
#
# Deliberately stops at the catalog. Schemas, volumes and pipelines are
# application artifacts and belong to the Asset Bundle — a DAB pipeline creates
# its own target schema, and in `mode: development` every engineer gets their
# own prefixed copy. If Terraform also declared them the two would fight over
# ownership, and engineers could not create anything of their own without a
# Terraform change.
#
# Assumes the workspace has a Unity Catalog metastore assigned. Databricks
# auto-provisions and assigns one per region for accounts created since late
# 2023; `terraform apply` fails loudly here if that is not the case, and the fix
# is a one-time metastore creation at account level.

# A single credential shared by all environments. Isolation comes from the
# external locations below — each scoped to one container — not from having
# several identities.
resource "databricks_storage_credential" "uc" {
  name          = "sc-${var.project}"
  comment       = "Managed identity used by Unity Catalog to reach the project's ADLS account."
  force_destroy = var.force_destroy

  azure_managed_identity {
    access_connector_id = data.terraform_remote_state.platform.outputs.access_connector_id
  }
}

resource "databricks_external_location" "env" {
  for_each = var.environments

  name            = "el-${var.project}-${each.key}"
  url             = data.terraform_remote_state.platform.outputs.container_urls[each.key]
  credential_name = databricks_storage_credential.uc.name
  comment         = "Managed storage root for the ${each.key} catalog."
  force_destroy   = var.force_destroy
}

resource "databricks_catalog" "env" {
  for_each = var.environments

  name          = "orders_${each.key}"
  storage_root  = databricks_external_location.env[each.key].url
  comment       = "Orders data for the ${each.key} environment. Managed by Terraform."
  force_destroy = var.force_destroy

  properties = {
    environment = each.key
  }
}

# ---------------------------------------------------------------------------
# Grants
#
# Privileges granted on a catalog are inherited by every schema, table and
# volume inside it, so this single resource per environment is the whole access
# model — including for objects the bundle has not created yet.
# ---------------------------------------------------------------------------

resource "databricks_grants" "catalog" {
  for_each = var.environments

  catalog = databricks_catalog.env[each.key].name

  # The execution SP owns its environment's catalog outright: it creates the
  # schemas and volume on deploy, and a full refresh drops and recreates every
  # table. dev has no SP — engineers deploy there as themselves.
  dynamic "grant" {
    for_each = each.value.create_service_principal ? [each.key] : []
    content {
      principal  = databricks_service_principal.env[grant.value].application_id
      privileges = ["ALL_PRIVILEGES"]
    }
  }

  grant {
    principal  = databricks_group.engineers.display_name
    privileges = each.value.engineer_privileges
  }
}
