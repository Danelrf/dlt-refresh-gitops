#!/usr/bin/env bash
# Destroys everything this project created, including the parts Terraform does
# not manage.
#
# `terraform destroy` alone is not enough. bootstrap.sh created the state
# storage account, the Entra application, its role assignments and the GitHub
# Environments — none of which appear in any Terraform state, because they had
# to exist before Terraform could run. This script removes those too.
#
# Order matters: Terraform state must survive until the Terraform-managed
# resources are gone, so the state account is deleted last.
#
# Usage:  ./teardown.sh
#         PROJECT=foo ./teardown.sh
set -euo pipefail

cd "$(dirname "$0")"

PROJECT=${PROJECT:-dltrefresh}
STATE_RG="rg-${PROJECT}-tfstate"
APP_NAME="sp-${PROJECT}-terraform"

REPO=${REPO:-$(gh repo view --json nameWithOwner -q .nameWithOwner)}
SUBSCRIPTION=$(az account show --query id -o tsv)
SUB_NAME=$(az account show --query name -o tsv)

cat <<EOF
This will PERMANENTLY DELETE:

  Terraform-managed
    - Unity Catalog catalogs orders_dev / orders_tst / orders_prd, and all data
      in them
    - the Databricks workspace, ADLS account and access connector
    - resource group rg-${PROJECT}
    - the tst and prd Databricks service principals and federation policies

  Created by bootstrap.sh, invisible to Terraform
    - Entra application ${APP_NAME} and its role assignments
    - GitHub Environments infra / tst / prd and their variables
    - resource group ${STATE_RG}, including all Terraform state

  Subscription: ${SUB_NAME} (${SUBSCRIPTION})
  Repository:   ${REPO}

There is no undo. Blob soft delete protects the state account for 30 days, but
nothing protects the data in the catalogs.

EOF
read -r -p "Type the project name (${PROJECT}) to confirm: " reply
[ "$reply" = "$PROJECT" ] || { echo "Aborted."; exit 1; }

# ---------------------------------------------------------------------------
# 1. Terraform, in reverse dependency order
#
# Stage 2 first: it reads stage 1's outputs, so destroying stage 1 first would
# strand it with no way to resolve the workspace it is meant to clean up.
# ---------------------------------------------------------------------------

destroy_stage() {
  local stage=$1
  echo
  echo "==> terraform destroy — ${stage}"
  if [ ! -f "backend.${stage}.tfbackend" ]; then
    echo "    no backend config; assuming never applied, skipping"
    return
  fi
  (
    cd "$stage"
    terraform init -input=false -backend-config="../backend.${stage}.tfbackend" >/dev/null
    terraform destroy -input=false -auto-approve
  ) || echo "    destroy reported errors — continuing, and check manually afterwards"
}

destroy_stage databricks
destroy_stage platform

# ---------------------------------------------------------------------------
# 2. The Entra application
#
# Deleting the application removes its service principal and federated
# credentials with it. Role assignments are removed first so they do not linger
# as orphaned entries referencing a deleted principal.
# ---------------------------------------------------------------------------

echo
echo "==> Entra application ${APP_NAME}"
APP_ID=$(az ad app list --display-name "$APP_NAME" --query "[0].appId" -o tsv 2>/dev/null || true)
if [ -n "$APP_ID" ]; then
  SP_OID=$(az ad sp show --id "$APP_ID" --query id -o tsv 2>/dev/null || true)
  if [ -n "$SP_OID" ]; then
    echo "    removing role assignments"
    az role assignment delete --assignee "$SP_OID" --scope "/subscriptions/${SUBSCRIPTION}" -o none 2>/dev/null || true
  fi
  az ad app delete --id "$APP_ID" -o none
  echo "    deleted ${APP_ID}"
else
  echo "    not found, skipping"
fi

# ---------------------------------------------------------------------------
# 3. GitHub Environments
#
# Deleting an environment removes its variables and protection rules. The
# repository-level variables bootstrap.sh set are removed separately.
# ---------------------------------------------------------------------------

echo
echo "==> GitHub Environments"
for ENV in infra tst prd; do
  if gh api -X DELETE "repos/${REPO}/environments/${ENV}" --silent 2>/dev/null; then
    echo "    deleted ${ENV}"
  else
    echo "    ${ENV} not found, skipping"
  fi
done

echo "==> Repository variables"
for VAR in ARM_CLIENT_ID ARM_TENANT_ID ARM_SUBSCRIPTION_ID \
           TF_STATE_RESOURCE_GROUP TF_STATE_STORAGE_ACCOUNT TF_STATE_CONTAINER \
           TF_PROJECT TF_LOCATION DATABRICKS_ACCOUNT_ID; do
  gh variable delete "$VAR" --repo "$REPO" 2>/dev/null && echo "    deleted ${VAR}" || true
done

# ---------------------------------------------------------------------------
# 4. Terraform state — last, because everything above needed it
# ---------------------------------------------------------------------------

echo
echo "==> Resource group ${STATE_RG}"
if az group show -n "$STATE_RG" -o none 2>/dev/null; then
  az group delete -n "$STATE_RG" --yes --no-wait
  echo "    deletion started (running in the background)"
else
  echo "    not found, skipping"
fi

echo
echo "==> Local files"
rm -f backend.platform.tfbackend backend.databricks.tfbackend
rm -f platform/terraform.tfvars databricks/terraform.tfvars
rm -rf platform/.terraform databricks/.terraform
echo "    removed generated backend configs, tfvars and .terraform directories"

cat <<EOF

────────────────────────────────────────────────────────────────────────
Teardown complete.

Worth checking by hand:
  - Databricks account console: the account itself survives (it is tied to the
    Entra tenant, not to any workspace) and may still list the deleted
    workspace's service principals. Remove them if you care.
  - az group list — confirm rg-${PROJECT} and ${STATE_RG} are gone.
  - Soft-deleted Entra applications remain recoverable for 30 days:
    az ad app list --show-deleted
────────────────────────────────────────────────────────────────────────
EOF
