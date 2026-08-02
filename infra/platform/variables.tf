variable "subscription_id" {
  description = "Azure subscription the infrastructure is created in."
  type        = string
}

variable "tenant_id" {
  description = "Entra ID tenant that owns the subscription."
  type        = string
}

variable "use_oidc" {
  description = "Authenticate to Azure with GitHub Actions OIDC. True in CI, false when running locally against your az CLI session."
  type        = bool
  default     = false
}

variable "project" {
  description = "Short lowercase name used as the prefix for every resource. Must be alphanumeric — it ends up inside a storage account name."
  type        = string
  default     = "dltrefresh"

  validation {
    condition     = can(regex("^[a-z0-9]{3,12}$", var.project))
    error_message = "project must be 3-12 lowercase alphanumeric characters."
  }
}

variable "location" {
  description = "Azure region. Must offer the VM size in databricks.yml's node_type_id — the bundle's pipeline runs on classic compute."
  type        = string
  default     = "westeurope"
}

# Only the names are needed here: this stage creates one storage container per
# environment. Who may do what inside them is decided in stage 2.
variable "environments" {
  description = "Environment names, matching the targets in databricks.yml."
  type        = list(string)
  default     = ["dev", "tst", "prd"]
}

variable "tags" {
  description = "Tags applied to every Azure resource."
  type        = map(string)
  default = {
    project    = "dlt-refresh-gitops"
    managed_by = "terraform"
  }
}
