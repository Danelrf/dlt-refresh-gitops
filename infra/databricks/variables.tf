variable "databricks_account_id" {
  description = "Databricks account ID. Found at https://accounts.azuredatabricks.net under the user menu."
  type        = string
}

variable "github_repo" {
  description = "owner/name of the GitHub repository allowed to authenticate as the deploy service principals."
  type        = string
  default     = "Danelrf/dlt-refresh-gitops"

  validation {
    condition     = can(regex("^[^/]+/[^/]+$", var.github_repo))
    error_message = "github_repo must be in owner/name form."
  }
}

variable "project" {
  description = "Short lowercase name used as the prefix for Databricks objects."
  type        = string
  default     = "dltrefresh"
}

# Where stage 1 keeps its state, so this stage can read its outputs.
variable "state_resource_group" {
  description = "Resource group holding the Terraform state storage account."
  type        = string
}

variable "state_storage_account" {
  description = "Storage account holding Terraform state."
  type        = string
}

variable "state_container" {
  description = "Blob container holding Terraform state."
  type        = string
  default     = "tfstate"
}

# Per-environment access model. This is the security policy of the whole repo
# expressed as data — changing who can read prd is a reviewable diff here.
variable "environments" {
  description = "Deployment environments, keyed by the databricks.yml target name."
  type = map(object({
    # dev has no CI identity: engineers deploy there from their own machines as
    # themselves. tst and prd are only ever deployed by their service principal.
    create_service_principal = bool
    # What the `engineers` group may do in this environment's catalog.
    # Privileges granted on a catalog are inherited by everything inside it.
    engineer_privileges = list(string)
  }))
  default = {
    # Engineers' own sandbox. ALL_PRIVILEGES includes CREATE_SCHEMA, which is
    # what lets `databricks bundle deploy --target dev` create each engineer's
    # personally-prefixed schemas and volume.
    dev = {
      create_service_principal = false
      engineer_privileges      = ["ALL_PRIVILEGES"]
    }
    # Shared integration environment: engineers read what the pipeline produced
    # — that is what tst is for — but the SP owns the objects.
    tst = {
      create_service_principal = true
      engineer_privileges      = ["USE_CATALOG", "USE_SCHEMA", "SELECT", "READ_VOLUME", "EXECUTE"]
    }
    # Production. BROWSE lets engineers see that objects exist and inspect
    # lineage without reading a single row. No SELECT, by design.
    prd = {
      create_service_principal = true
      engineer_privileges      = ["BROWSE"]
    }
  }
}

# This is a learning project, and the most important property of a learning
# environment is that you can delete it. `true` lets `terraform destroy` drop
# catalogs, external locations and the storage credential even when they hold
# data — including prd.
#
# For anything real, set this to false. The protection it gives up is exactly
# the protection you want when the data matters: a destroy that would discard
# production tables fails instead of succeeding quietly.
variable "force_destroy" {
  description = "Allow terraform destroy to remove Unity Catalog objects that still contain data."
  type        = bool
  default     = true
}
