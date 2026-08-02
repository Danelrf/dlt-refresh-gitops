# Consumed by stage 2 (infra/databricks) through terraform_remote_state, and by
# bootstrap.sh when it fills in the GitHub Environments.

output "workspace_url" {
  description = "Value for DATABRICKS_HOST in the GitHub Environments."
  value       = "https://${azurerm_databricks_workspace.this.workspace_url}"
}

output "workspace_id" {
  description = "Numeric Databricks workspace ID, used to assign account principals to this workspace."
  value       = azurerm_databricks_workspace.this.workspace_id
}

output "workspace_resource_id" {
  description = "ARM resource ID of the Databricks workspace."
  value       = azurerm_databricks_workspace.this.id
}

output "access_connector_id" {
  description = "ARM resource ID of the Access Connector backing the UC storage credential."
  value       = azurerm_databricks_access_connector.uc.id
}

output "storage_account_name" {
  description = "ADLS Gen2 account holding Unity Catalog managed storage."
  value       = azurerm_storage_account.uc.name
}

output "container_urls" {
  description = "abfss:// URL per environment, used as each catalog's storage root."
  value = {
    for env, c in azurerm_storage_container.env :
    env => "abfss://${c.name}@${azurerm_storage_account.uc.name}.dfs.core.windows.net/"
  }
}
