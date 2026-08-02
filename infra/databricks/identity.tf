# Execution identities.
#
# These are Databricks-managed service principals, deliberately not Entra ones:
# they never call an Azure API (storage is reached through the Access
# Connector's managed identity, not through them), so giving them an Entra
# presence would only widen what they could be granted by mistake — and would
# force the Terraform runner to hold directory write permission.
#
# They hold no secret of any kind. Each is bound by a federation policy to one
# GitHub Environment in one repository; a workflow run in any other context
# cannot authenticate as them.

locals {
  ci_environments = {
    for name, cfg in var.environments : name => cfg
    if cfg.create_service_principal
  }
}

resource "databricks_service_principal" "env" {
  provider = databricks.account

  for_each = local.ci_environments

  display_name = "sp-${var.project}-${each.key}"

  # The pipeline uses classic compute (databricks.yml sets `serverless: false`),
  # so it provisions its own cluster as the `run_as` principal — which is this
  # service principal in tst and prd. Without the entitlement, every update
  # fails at cluster provisioning with PERMISSION_DENIED.
  #
  # This is unrestricted cluster creation: these principals can create clusters
  # of any shape, not just the one the pipeline declares. Bounding it means
  # attaching a cluster policy and granting CAN_USE on it instead.
  #
  # SQL warehouse access is still not needed.
  workspace_access      = true
  allow_cluster_create  = true
  databricks_sql_access = false
}

# The whole point of the design: authentication is bound to the GitHub
# Environment, which is itself protected by deployment rules. A prd token can
# only be minted by a job that declares `environment: prd` in this repository,
# and that job cannot start until the environment's reviewers approve.
resource "databricks_service_principal_federation_policy" "env" {
  provider = databricks.account

  for_each = local.ci_environments

  service_principal_id = tonumber(databricks_service_principal.env[each.key].id)
  policy_id            = "github-actions-${each.key}"
  description          = "GitHub Actions OIDC for ${var.github_repo}, environment ${each.key}."

  oidc_policy = {
    issuer        = "https://token.actions.githubusercontent.com"
    audiences     = [var.databricks_account_id]
    subject_claim = "sub"
    subject       = "repo:${var.github_repo}:environment:${each.key}"
  }
}

# Account principals must be explicitly assigned to a workspace before they can
# do anything in it.
resource "databricks_mws_permission_assignment" "env" {
  provider = databricks.account

  for_each = local.ci_environments

  workspace_id = data.terraform_remote_state.platform.outputs.workspace_id
  principal_id = databricks_service_principal.env[each.key].id
  permissions  = ["USER"]
}

# The `engineers` group referenced by databricks.yml's permissions blocks and by
# every catalog grant. Membership is managed outside Terraform — add engineers
# in the account console, or extend this file with databricks_group_member.
resource "databricks_group" "engineers" {
  provider = databricks.account

  display_name     = "engineers"
  workspace_access = true
}

resource "databricks_mws_permission_assignment" "engineers" {
  provider = databricks.account

  workspace_id = data.terraform_remote_state.platform.outputs.workspace_id
  principal_id = databricks_group.engineers.id
  permissions  = ["USER"]
}
