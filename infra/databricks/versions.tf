# Stage 2: everything inside Databricks.
#
# Two providers, because federation policies and service principals are
# account-level objects while catalogs and grants are workspace-level ones.
# Both authenticate as the Terraform runner's Entra service principal, which
# must be BOTH an Azure subscription contributor and a Databricks account admin.

terraform {
  required_version = ">= 1.9.0"

  required_providers {
    databricks = {
      source  = "databricks/databricks"
      version = "~> 1.60"
    }
  }

  # Configured at init time by bootstrap.sh:
  #   terraform init -backend-config=../backend.databricks.tfbackend
  backend "azurerm" {}
}

# Both providers authenticate through the ambient Azure CLI session — your own
# when running locally, the Terraform runner's after `azure/login` in CI.
#
# Deliberately no `azure_client_id`: setting it tells the provider to
# authenticate *as* that principal, which requires a credential we do not have
# (and by ADR 0008 do not want to exist). Leaving it unset makes the provider
# use whoever is already logged in, which is correct in both contexts.

# Workspace-level: catalogs, external locations, grants.
provider "databricks" {
  host = data.terraform_remote_state.platform.outputs.workspace_url
}

# Account-level: service principals, federation policies, workspace assignment.
provider "databricks" {
  alias      = "account"
  host       = "https://accounts.azuredatabricks.net"
  account_id = var.databricks_account_id
}

# Stage 1's outputs. Reading them as remote state rather than duplicating the
# resource names keeps the two stages honestly coupled: rename something in
# platform/ and this stage follows automatically.
data "terraform_remote_state" "platform" {
  backend = "azurerm"

  config = {
    resource_group_name  = var.state_resource_group
    storage_account_name = var.state_storage_account
    container_name       = var.state_container
    key                  = "platform.tfstate"
    use_azuread_auth     = true
  }
}
