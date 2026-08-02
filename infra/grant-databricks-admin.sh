#!/usr/bin/env bash
# Grants the Terraform runner service principal the Databricks account_admin
# role, via the Accounts Access Control API instead of the account console UI.
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
PRINCIPAL="servicePrincipals/${APP_ID}"
RESOURCE="accounts/${DATABRICKS_ACCOUNT_ID}"
RULESET_NAME="${RESOURCE}/ruleSets/default"

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
# 2. Find the exact role string for "account admin". Docs disagree on
#    whether it's account_admin or account.admin -- ask the API instead of
#    guessing.
# ---------------------------------------------------------------------------

echo "==> Looking up the account admin role"
ROLES_JSON=$(databricks account access-control get-assignable-roles-for-resource \
  "$RESOURCE" --profile "$PROFILE" -o json)
ROLE=$(jq -r '(.roles // [])[] | select(test("account.?admin"; "i"))' <<<"$ROLES_JSON" | head -1)
if [ -z "$ROLE" ]; then
  echo "    could not find an account-admin role among:" >&2
  echo "$ROLES_JSON" >&2
  exit 1
fi
echo "    ${ROLE}"

# ---------------------------------------------------------------------------
# 3. Register the service principal at account level, if it isn't already.
# ---------------------------------------------------------------------------

echo "==> Registering ${APP_NAME} at account level"
if databricks account service-principals list --profile "$PROFILE" -o json \
    | jq -e --arg id "$APP_ID" 'any(.[]; .applicationId == $id)' >/dev/null; then
  echo "    already registered"
else
  databricks account service-principals create \
    --application-id "$APP_ID" --display-name "$APP_NAME" \
    --profile "$PROFILE" -o none
  echo "    registered"
fi

# ---------------------------------------------------------------------------
# 4. Grant the role: read -> merge -> write with the etag, so a concurrent
#    change to the rule set is detected rather than silently overwritten.
# ---------------------------------------------------------------------------

echo "==> Reading current rule set"
CURRENT=$(databricks account access-control get-rule-set "$RULESET_NAME" "" \
  --profile "$PROFILE" -o json)

ALREADY=$(jq -r --arg role "$ROLE" --arg principal "$PRINCIPAL" '
  [.grant_rules[]? | select(.role == $role) | .principals[]?] | index($principal) != null
' <<<"$CURRENT")

if [ "$ALREADY" = true ]; then
  echo "==> ${APP_NAME} is already an account admin"
else
  echo "==> Granting ${ROLE} to ${APP_NAME}"
  REQUEST=$(jq -c --arg name "$RULESET_NAME" --arg role "$ROLE" --arg principal "$PRINCIPAL" '
    {
      name: $name,
      rule_set: {
        name: $name,
        etag: .etag,
        grant_rules: (
          [.grant_rules[]? | select(.role != $role)]
          + [{role: $role,
              principals: (([.grant_rules[]? | select(.role == $role) | .principals[]?]) + [$principal] | unique)}]
        )
      }
    }
  ' <<<"$CURRENT")
  databricks account access-control update-rule-set --profile "$PROFILE" --json "$REQUEST" -o none
  echo "    granted"
fi

cat <<EOF

────────────────────────────────────────────────────────────────────────
${APP_NAME} (${APP_ID}) is now a Databricks account admin.

One step still can't be automated -- the account ID doesn't exist to query
until a human reads it off the console:

  gh variable set DATABRICKS_ACCOUNT_ID --repo <owner>/<repo> --body ${DATABRICKS_ACCOUNT_ID}

and set databricks_account_id = "${DATABRICKS_ACCOUNT_ID}" in
infra/databricks/terraform.tfvars (gitignored, local runs only).
────────────────────────────────────────────────────────────────────────
EOF
