#!/usr/bin/env bash
# One-time local bootstrap. Everything after this runs in CI.
#
# Creates the minimum that cannot create itself:
#   1. the storage account holding Terraform state
#   2. the Entra service principal CI authenticates as
#   3. that principal's GitHub federated credentials (so it needs no secret)
#   4. its Azure role assignments
#   5. the GitHub Environment variables the terraform workflow reads
#
# Idempotent: re-running converges rather than duplicating. Safe to run again
# after changing PROJECT or the repository.
#
# Usage:  ./bootstrap.sh
#         PROJECT=foo LOCATION=northeurope ./bootstrap.sh
set -euo pipefail #exit on failure, unset vars as failure, fail if either thing fails

cd "$(dirname "$0")"

PROJECT=${PROJECT:-dltrefresh}
LOCATION=${LOCATION:-westeurope}
CONTAINER=tfstate
STATE_RG="rg-${PROJECT}-tfstate"
APP_NAME="sp-${PROJECT}-terraform"

# Checks commands exists or exits.
command -v az >/dev/null || { echo "az CLI not found" >&2; exit 1; }
command -v gh >/dev/null || { echo "gh CLI not found" >&2; exit 1; }
command -v jq >/dev/null || { echo "jq not found" >&2; exit 1; }

REPO=${REPO:-$(gh repo view --json nameWithOwner -q .nameWithOwner)}
SUBSCRIPTION=$(az account show --query id -o tsv)
TENANT=$(az account show --query tenantId -o tsv)
SUB_NAME=$(az account show --query name -o tsv)

# This will be printed to confirm
cat <<EOF 
Bootstrapping:
  Repository:   ${REPO}
  Subscription: ${SUB_NAME} (${SUBSCRIPTION})
  Tenant:       ${TENANT}
  Project:      ${PROJECT}
  Location:     ${LOCATION}

EOF
# prompt for confirmation, exit if not y or Y
read -r -p "Continue? [y/N] " reply
[[ "$reply" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 1; }

# ---------------------------------------------------------------------------
# 1. Terraform state storage
# ---------------------------------------------------------------------------

# Names are globally unique and allow no separators. Deriving the suffix from
# the subscription id keeps this deterministic across re-runs.
SUFFIX=$(printf '%s' "$SUBSCRIPTION" | shasum -a 256 | cut -c1-6)
SA="st${PROJECT}tf${SUFFIX}"

echo "==> Resource group ${STATE_RG}"
az group create -n "$STATE_RG" -l "$LOCATION" -o none

echo "==> Storage account ${SA}"
az storage account create \
  --name "$SA" --resource-group "$STATE_RG" --location "$LOCATION" \
  --sku Standard_LRS --kind StorageV2 --min-tls-version TLS1_2 \
  --allow-blob-public-access false --allow-shared-key-access false \
  -o none

# State is the only record of what exists. An accidental overwrite or a failed
# apply must be recoverable.
echo "==> Blob versioning and soft delete"
az storage account blob-service-properties update \
  --account-name "$SA" --resource-group "$STATE_RG" \
  --enable-versioning true --enable-delete-retention true --delete-retention-days 30 \
  -o none

SA_ID=$(az storage account show -n "$SA" -g "$STATE_RG" --query id -o tsv)

# Shared keys are disabled, so data-plane access is Entra-based and needs an
# explicit role — being subscription Owner is not sufficient by itself.
echo "==> Granting yourself data-plane access to state"
USER_OID=$(az ad signed-in-user show --query id -o tsv)
az role assignment create \
  --assignee-object-id "$USER_OID" --assignee-principal-type User \
  --role "Storage Blob Data Contributor" --scope "$SA_ID" \
  -o none 2>/dev/null || echo "    (already assigned)"

echo "==> Container ${CONTAINER}"
for attempt in $(seq 1 12); do
  if az storage container create --name "$CONTAINER" --account-name "$SA" \
      --auth-mode login -o none 2>/dev/null; then
    break
  fi
  [ "$attempt" -eq 12 ] && { echo "    role assignment never propagated" >&2; exit 1; }
  echo "    waiting for role assignment to propagate (${attempt}/12)"
  sleep 10
done

# ---------------------------------------------------------------------------
# 2. Terraform runner service principal
# ---------------------------------------------------------------------------

echo "==> Entra application ${APP_NAME}"
APP_ID=$(az ad app list --display-name "$APP_NAME" --query "[0].appId" -o tsv)
if [ -z "$APP_ID" ]; then
  APP_ID=$(az ad app create --display-name "$APP_NAME" --query appId -o tsv)
  echo "    created ${APP_ID}"
else
  echo "    exists ${APP_ID}"
fi

if ! az ad sp show --id "$APP_ID" -o none 2>/dev/null; then
  az ad sp create --id "$APP_ID" -o none
  echo "    service principal created"
fi
SP_OID=$(az ad sp show --id "$APP_ID" --query id -o tsv)

# ---------------------------------------------------------------------------
# 3. Federated credentials — this is what replaces a client secret.
#
# The subject must match GitHub's OIDC token exactly. `environment:infra` means
# only a job declaring `environment: infra` can authenticate; `pull_request`
# covers the plan-only job on PRs.
# ---------------------------------------------------------------------------

add_federated_credential() {
  local name=$1 subject=$2
  echo "==> Federated credential ${name}"
  if az ad app federated-credential show --id "$APP_ID" --federated-credential-id "$name" -o none 2>/dev/null; then
    echo "    exists"
    return
  fi
  az ad app federated-credential create --id "$APP_ID" --parameters "$(jq -nc \
    --arg name "$name" --arg subject "$subject" \
    '{name: $name,
      issuer: "https://token.actions.githubusercontent.com",
      subject: $subject,
      description: "GitHub Actions OIDC",
      audiences: ["api://AzureADTokenExchange"]}')" -o none
  echo "    created"
}

add_federated_credential "github-environment-infra" "repo:${REPO}:environment:infra"
add_federated_credential "github-pull-request"      "repo:${REPO}:pull_request"

# ---------------------------------------------------------------------------
# 4. Azure roles
#
# Contributor alone is not enough: platform/main.tf creates a role assignment
# (Access Connector -> storage), which needs a role that can write RBAC.
# Scoped to this subscription only.
# ---------------------------------------------------------------------------

assign_role() {
  local role=$1 scope=$2
  echo "==> Role ${role}"
  az role assignment create \
    --assignee-object-id "$SP_OID" --assignee-principal-type ServicePrincipal \
    --role "$role" --scope "$scope" -o none 2>/dev/null \
    && echo "    assigned" || echo "    (already assigned)"
}

assign_role "Contributor"                          "/subscriptions/${SUBSCRIPTION}"
assign_role "Role Based Access Control Administrator" "/subscriptions/${SUBSCRIPTION}"
assign_role "Storage Blob Data Contributor"        "$SA_ID"

# ---------------------------------------------------------------------------
# 5. Local Terraform configuration
# ---------------------------------------------------------------------------

write_backend() {
  local stage=$1
  cat > "backend.${stage}.tfbackend" <<EOF
# Generated by bootstrap.sh — safe to commit, contains no secrets.
resource_group_name  = "${STATE_RG}"
storage_account_name = "${SA}"
container_name       = "${CONTAINER}"
key                  = "${stage}.tfstate"
use_azuread_auth     = true
EOF
  echo "==> Wrote backend.${stage}.tfbackend"
}

write_backend platform
write_backend databricks

cat > platform/terraform.tfvars <<EOF
# Generated by bootstrap.sh. No secrets — safe to commit.
subscription_id = "${SUBSCRIPTION}"
tenant_id       = "${TENANT}"
project         = "${PROJECT}"
location        = "${LOCATION}"
EOF
echo "==> Wrote platform/terraform.tfvars"

cat > databricks/terraform.tfvars <<EOF
# Generated by bootstrap.sh. No secrets.
# databricks_account_id must be filled in by hand: see the next steps printed
# by this script.
github_repo           = "${REPO}"
project               = "${PROJECT}"
state_resource_group  = "${STATE_RG}"
state_storage_account = "${SA}"
state_container       = "${CONTAINER}"
databricks_account_id = ""
EOF
echo "==> Wrote databricks/terraform.tfvars"

# ---------------------------------------------------------------------------
# 6. GitHub Environment for the Terraform workflow
# ---------------------------------------------------------------------------

# These are repository-level variables rather than files in the repo. None of
# them is a credential, but this repository is public and there is no reason to
# publish subscription, tenant and account identifiers. GitHub variables are
# visible only to workflow runs.
#
# Repo-level (not environment-level) because the plan job runs on pull_request
# and so cannot bind to an environment. The `infra` environment gates apply.
echo "==> GitHub Environment 'infra'"
gh api -X PUT "repos/${REPO}/environments/infra" --silent

set_var() {
  printf '%s' "$2" | gh variable set "$1" --repo "$REPO"
  echo "    ${1}"
}

echo "==> Repository variables"
set_var ARM_CLIENT_ID          "$APP_ID"
set_var ARM_TENANT_ID          "$TENANT"
set_var ARM_SUBSCRIPTION_ID    "$SUBSCRIPTION"
set_var TF_STATE_RESOURCE_GROUP "$STATE_RG"
set_var TF_STATE_STORAGE_ACCOUNT "$SA"
set_var TF_STATE_CONTAINER     "$CONTAINER"
set_var TF_PROJECT             "$PROJECT"
set_var TF_LOCATION            "$LOCATION"

cat <<EOF

────────────────────────────────────────────────────────────────────────
Bootstrap complete. The Databricks account does not exist yet — it is
created as a side effect of the first workspace, so these steps run in
this order:

1. Apply stage 1, which creates that workspace (and with it, the account):

       cd infra/platform && terraform init -backend-config=../backend.platform.tfbackend && terraform apply

2. Visit https://accounts.azuredatabricks.net once as an Entra ID Global
   Administrator. Databricks auto-promotes the first Global Admin to log in
   there to account admin — this is the one truly manual step, it is how
   the first admin comes to exist at all. Copy the account ID while you're
   in there (top-right user menu).

3. Make the Terraform runner a Databricks account admin too, so CI can
   manage the account from here on:

       cd ../.. && DATABRICKS_ACCOUNT_ID=<account-id> ./grant-databricks-admin.sh

   This signs you in as the admin from step 2 and does the rest —
   registering the service principal and granting the role — via the
   Accounts Access Control API instead of more console clicking. It also
   prints the DATABRICKS_ACCOUNT_ID commands you still need to run by hand.

Then, locally for the first run:

   cd infra/databricks  && terraform init -backend-config=../backend.databricks.tfbackend  && terraform apply
   cd ..                && ./push-github-config.sh

After that, every change goes through .github/workflows/terraform.yml —
plan on PR, apply on merge to main. You should not need to run apply by hand
again.
────────────────────────────────────────────────────────────────────────
EOF
