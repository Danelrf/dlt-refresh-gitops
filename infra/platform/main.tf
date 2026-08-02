resource "azurerm_resource_group" "this" {
  name     = "rg-${var.project}"
  location = var.location
  tags     = var.tags
}

# Storage account names are globally unique and allow no separators, hence the
# random suffix rather than a readable name.
resource "random_string" "suffix" {
  length  = 6
  special = false
  upper   = false
  numeric = true
}

# `premium` is not optional: Unity Catalog, pipeline ACLs and service principal
# permissions — everything the governance model in this repo relies on — are
# premium-tier features.
resource "azurerm_databricks_workspace" "this" {
  name                = "dbw-${var.project}"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  sku                 = "premium"
  tags                = var.tags
}

# Unity Catalog requires a hierarchical-namespace (ADLS Gen2) account.
resource "azurerm_storage_account" "uc" {
  name                             = "st${var.project}${random_string.suffix.result}"
  resource_group_name              = azurerm_resource_group.this.name
  location                         = azurerm_resource_group.this.location
  account_tier                     = "Standard"
  account_replication_type         = "LRS"
  account_kind                     = "StorageV2"
  is_hns_enabled                   = true
  min_tls_version                  = "TLS1_2"
  https_traffic_only_enabled       = true
  allow_nested_items_to_be_public  = false
  cross_tenant_replication_enabled = false
  tags                             = var.tags
}

# One container per environment: dev, tst and prd data never share a storage
# boundary, so a mis-scoped credential cannot read across environments.
resource "azurerm_storage_container" "env" {
  for_each = toset(var.environments)

  name                  = each.value
  storage_account_id    = azurerm_storage_account.uc.id
  container_access_type = "private"
}

# Unity Catalog reaches storage through this managed identity — no account keys
# or SAS tokens exist anywhere in this design.
resource "azurerm_databricks_access_connector" "uc" {
  name                = "dbac-${var.project}"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  tags                = var.tags

  identity {
    type = "SystemAssigned"
  }
}

# Creating this is why the Terraform runner needs a role-assignment-capable role
# (Role Based Access Administrator), not merely Contributor.
resource "azurerm_role_assignment" "uc_storage" {
  scope                = azurerm_storage_account.uc.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_databricks_access_connector.uc.identity[0].principal_id
}
