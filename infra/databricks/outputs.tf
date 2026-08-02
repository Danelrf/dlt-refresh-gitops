# Values the deploy workflow needs as GitHub Environment variables. None of
# them are secret — that is the point of federation. push-github-config.sh
# copies them into place.

output "workspace_url" {
  description = "Value for DATABRICKS_HOST in each GitHub Environment."
  value       = data.terraform_remote_state.platform.outputs.workspace_url
}

output "service_principal_client_ids" {
  description = "Value for DATABRICKS_CLIENT_ID in each GitHub Environment."
  value       = { for k, v in databricks_service_principal.env : k => v.application_id }
}

output "catalogs" {
  description = "Catalog name per environment; matches the `catalog` variable in databricks.yml."
  value       = { for k, v in databricks_catalog.env : k => v.name }
}

output "federation_subjects" {
  description = "The exact OIDC subject each service principal will accept. A workflow job must run with a matching `environment:` to authenticate."
  value = {
    for k, v in databricks_service_principal_federation_policy.env :
    k => v.oidc_policy.subject
  }
}
