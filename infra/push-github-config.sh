#!/usr/bin/env bash
# Creates the tst and prd GitHub Environments and fills in the variables
# .github/workflows/deploy.yml expects.
#
# Note what is absent: there are no secrets. The deploy identities authenticate
# by federation, so everything below is public information — a client ID and a
# workspace URL are useless without a matching OIDC token from this repository's
# tst or prd environment.
#
# Usage:  ./push-github-config.sh
#         REPO=owner/name ./push-github-config.sh
set -euo pipefail

cd "$(dirname "$0")/databricks"

REPO=${REPO:-$(gh repo view --json nameWithOwner -q .nameWithOwner)}
echo "Repository: ${REPO}"

HOST=$(terraform output -raw workspace_url)
CLIENT_IDS=$(terraform output -json service_principal_client_ids)

for ENV in $(jq -r 'keys[]' <<<"$CLIENT_IDS"); do
  echo "==> Environment ${ENV}"

  # Idempotent: PUT on an existing environment leaves its protection rules and
  # required reviewers alone.
  gh api -X PUT "repos/${REPO}/environments/${ENV}" --silent

  printf '%s' "$HOST" | gh variable set DATABRICKS_HOST --env "$ENV" --repo "$REPO"
  jq -rj --arg e "$ENV" '.[$e]' <<<"$CLIENT_IDS" \
    | gh variable set DATABRICKS_CLIENT_ID --env "$ENV" --repo "$REPO"

  echo "    DATABRICKS_HOST, DATABRICKS_CLIENT_ID"
done

echo
echo "Federation subjects — a workflow job must match one of these exactly:"
terraform output -json federation_subjects | jq -r 'to_entries[] | "  \(.key): \(.value)"'

cat <<'EOF'

Remaining manual steps (policy, not plumbing — deliberately not automated):
  - Add required reviewers to the 'prd' and 'infra' environments
  - Create the 'refresh-audit' issue label
  - Branch protection per .github/CODEOWNERS
EOF
