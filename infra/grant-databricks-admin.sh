#!/usr/bin/env bash
# Grants the Terraform runner service principal the Databricks account_admin
# role, via the SCIM Service Principals API instead of the account console UI.
# account_admin is a `roles` attribute on the principal itself -- the same
# thing a human's first login into the console sets on them -- not a grant on
# any rule set; the Accounts Access Control / rule-set API does not cover it.
#
# This still needs a human: only an existing account admin can grant that role
# to anyone else, so the script authenticates interactively as one. What it
# replaces is the click-through in the console — everything after login is
# API-driven and safe to re-run.
#
# Run this AFTER the platform/ stage has applied (the Databricks account is
# created along with the first workspace) and AFTER a Global Administrator
# has logged into https://accounts.azuredatabricks.net once — that first
# login is what makes them an account admin at all; nothing can grant that
# role before someone holds it.
#
# The account ID itself cannot be discovered by API before you are
# authenticated to the account, so it must still be copied from the console
# by hand (top-right user menu at https://accounts.azuredatabricks.net) and
# passed in.
#
# Usage:  DATABRICKS_ACCOUNT_ID=<uuid> ./grant-databricks-admin.sh
#         PROJECT=foo DATABRICKS_ACCOUNT_ID=<uuid> ./grant-databricks-admin.sh
set -euo pipefail

cd "$(dirname "$0")"

PROJECT=${PROJECT:-dltrefresh}
APP_NAME="sp-${PROJECT}-terraform"
PROFILE="${PROJECT}-account"

command -v databricks >/dev/null || { echo "databricks CLI not found" >&2; exit 1; }
command -v az >/dev/null || { echo "az CLI not found" >&2; exit 1; }
command -v jq >/dev/null || { echo "jq not found" >&2; exit 1; }

: "${DATABRICKS_ACCOUNT_ID:?Set DATABRICKS_ACCOUNT_ID -- copy it from https://accounts.azuredatabricks.net (top-right user menu). It cannot be discovered by API before you are authenticated to the account.}"

APP_ID=$(az ad app list --display-name "$APP_NAME" --query "[0].appId" -o tsv)
[ -n "$APP_ID" ] || { echo "Entra application ${APP_NAME} not found -- run bootstrap.sh first" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 1. Sign in as a human account admin. This is the one manual step left --
#    everything below runs as this identity and requires it to already be an
#    account admin.
# ---------------------------------------------------------------------------

echo "==> Signing in to the account console as an account admin"
databricks auth login \
  --host https://accounts.azuredatabricks.net --account-id "$DATABRICKS_ACCOUNT_ID" \
  --profile "$PROFILE"

# ---------------------------------------------------------------------------
# 2. Find the service principal at account level. Azure Databricks accounts
#    sync service principals in from the Entra tenant automatically, so this
#    one likely already exists even though nothing here created it -- but
#    don't assume, since a from-scratch account may not have synced yet.
# ---------------------------------------------------------------------------

echo "==> Looking up ${APP_NAME} at account level"
SP_ID=$(databricks account service-principals list --profile "$PROFILE" -o json \
  | jq -r --arg id "$APP_ID" '.[] | select(.applicationId == $id) | .id')
if [ -z "$SP_ID" ]; then
  echo "    not synced yet, registering explicitly"
  SP_ID=$(databricks account service-principals create \
    --application-id "$APP_ID" --display-name "$APP_NAME" \
    --profile "$PROFILE" -o json | jq -r '.id')
fi
echo "    ${SP_ID}"

# ---------------------------------------------------------------------------
# 3. Grant account_admin. This is not a rule-set grant (that API only covers
#    narrower roles -- billing, marketplace, service-principal management,
#    etc; account_admin isn't in its assignable-roles list at all). It's a
#    SCIM `roles` attribute on the principal itself, the same shape the
#    console's own first-login bootstrap sets on a human user.
# ---------------------------------------------------------------------------

echo "==> Checking current roles"
ALREADY=$(databricks account service-principals get "$SP_ID" --profile "$PROFILE" -o json \
  | jq -r '[.roles[]?.value] | index("account_admin") != null')

if [ "$ALREADY" = true ]; then
  echo "==> ${APP_NAME} is already an account admin"
else
  echo "==> Granting account_admin to ${APP_NAME}"
  databricks account service-principals patch "$SP_ID" --profile "$PROFILE" --json '{
    "schemas": ["urn:ietf:params:scim:api:messages:2.0:PatchOp"],
    "Operations": [
      {"op": "add", "path": "roles", "value": [{"value": "account_admin"}]}
    ]
  }' >/dev/null
  echo "    granted"
fi

# ---------------------------------------------------------------------------
# 4. Unity Catalog needs a metastore assigned to the workspace before
#    catalog.tf can create anything in it. account_admin does not imply
#    this -- accounts created since late 2023 get one auto-provisioned per
#    region, but an older account (or one that already had a metastore from
#    unrelated prior work) may not have it assigned to *this* workspace.
# ---------------------------------------------------------------------------

WORKSPACE_NAME="dbw-${PROJECT}"
echo "==> Looking up workspace ${WORKSPACE_NAME}"
WORKSPACE_ID=$(databricks account workspaces list --profile "$PROFILE" -o json \
  | jq -r --arg name "$WORKSPACE_NAME" '.[] | select(.workspace_name == $name) | .workspace_id')
[ -n "$WORKSPACE_ID" ] || { echo "    not found -- has infra/platform applied yet?" >&2; exit 1; }
WORKSPACE_URL=$(databricks account workspaces get "$WORKSPACE_ID" --profile "$PROFILE" -o json | jq -r '.deployment_name' \
  | sed 's#$#.azuredatabricks.net#;s#^#https://#')
echo "    ${WORKSPACE_ID} (${WORKSPACE_URL})"

echo "==> Checking metastore assignment"
METASTORE_ID=$(databricks account metastore-assignments get "$WORKSPACE_ID" --profile "$PROFILE" -o json 2>/dev/null \
  | jq -r '.metastore_id // empty')
if [ -n "$METASTORE_ID" ]; then
  echo "    already assigned: ${METASTORE_ID}"
elif [ -n "${METASTORE_ID:=${DATABRICKS_METASTORE_ID:-}}" ]; then
  echo "    assigning ${METASTORE_ID} (from DATABRICKS_METASTORE_ID)"
  databricks account metastore-assignments create "$WORKSPACE_ID" "$METASTORE_ID" --profile "$PROFILE" >/dev/null
else
  METASTORES_JSON=$(databricks account metastores list --profile "$PROFILE" -o json)
  METASTORE_COUNT=$(jq 'length' <<<"$METASTORES_JSON")
  if [ "$METASTORE_COUNT" -eq 1 ]; then
    METASTORE_ID=$(jq -r '.[0].metastore_id' <<<"$METASTORES_JSON")
    echo "    no assignment yet; exactly one metastore exists (${METASTORE_ID}), assigning it"
    databricks account metastore-assignments create "$WORKSPACE_ID" "$METASTORE_ID" --profile "$PROFILE" >/dev/null
  else
    echo "    not assigned, and ${METASTORE_COUNT} metastores exist -- ambiguous." >&2
    echo "    Re-run with DATABRICKS_METASTORE_ID=<id> set to one of:" >&2
    jq -r '.[] | "      \(.metastore_id)  \(.name)  (\(.region))"' <<<"$METASTORES_JSON" >&2
    exit 1
  fi
fi

# ---------------------------------------------------------------------------
# 5. Grant the runner SP CREATE CATALOG and CREATE EXTERNAL LOCATION on that
#    metastore. account_admin does not imply these either -- they are
#    metastore-level Unity Catalog privileges, granted through the
#    workspace-scoped Permissions API (the account-level rule-set API used
#    for account_admin has no concept of a metastore).
# ---------------------------------------------------------------------------

echo "==> Signing in to the workspace for Unity Catalog grants"
databricks auth login --host "$WORKSPACE_URL" --profile "${PROFILE}-workspace"

echo "==> Checking current metastore grants"
NEEDED='["CREATE CATALOG", "CREATE EXTERNAL LOCATION"]'
CURRENT_GRANTS=$(databricks grants get metastore "$METASTORE_ID" --profile "${PROFILE}-workspace" -o json)
MISSING=$(jq -c --arg app_id "$APP_ID" --argjson needed "$NEEDED" '
  ([.privilege_assignments[]? | select(.principal == $app_id) | .privileges[]?]) as $have
  | $needed - $have
' <<<"$CURRENT_GRANTS")

if [ "$MISSING" = "[]" ]; then
  echo "==> ${APP_NAME} already holds the needed metastore privileges"
else
  echo "==> Granting $(jq -rc . <<<"$MISSING") to ${APP_NAME} on the metastore"
  REQUEST=$(jq -nc --arg app_id "$APP_ID" --argjson add "$MISSING" \
    '{changes: [{principal: $app_id, add: $add}]}')
  databricks grants update metastore "$METASTORE_ID" --profile "${PROFILE}-workspace" --json "$REQUEST" >/dev/null
  echo "    granted"
fi

cat <<EOF

────────────────────────────────────────────────────────────────────────
${APP_NAME} (${APP_ID}) is now a Databricks account admin, with the metastore
privileges infra/databricks/catalog.tf needs.

One step still can't be automated -- the account ID doesn't exist to query
until a human reads it off the console:

  gh variable set DATABRICKS_ACCOUNT_ID --repo <owner>/<repo> --body ${DATABRICKS_ACCOUNT_ID}

and set databricks_account_id = "${DATABRICKS_ACCOUNT_ID}" in
infra/databricks/terraform.tfvars (gitignored, local runs only).
────────────────────────────────────────────────────────────────────────
EOF
