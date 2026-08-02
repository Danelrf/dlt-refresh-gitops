# Stage 1: the Azure substrate. Nothing in here talks to the Databricks API —
# that is stage 2's job (infra/databricks). The split exists because the
# Databricks *account* only comes into existence once a workspace does, so
# account-level resources cannot be planned in the same apply that creates the
# workspace.

terraform {
  required_version = ">= 1.9.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }

  # Configured at init time by bootstrap.sh:
  #   terraform init -backend-config=../backend.platform.tfbackend
  backend "azurerm" {}
}

provider "azurerm" {
  features {}
  subscription_id = var.subscription_id
  tenant_id       = var.tenant_id

  # In CI, ARM_USE_OIDC=true makes the provider exchange the GitHub Actions
  # token for an Azure token. Locally it falls back to your az CLI session.
  use_oidc = var.use_oidc
}
