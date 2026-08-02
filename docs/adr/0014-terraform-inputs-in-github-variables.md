# 14. Terraform inputs live in GitHub variables, not committed tfvars

Date: 2026-08-01

## Status

Accepted

## Context

Both Terraform stages take inputs: subscription ID, tenant ID, the runner's
client ID, the Databricks account ID, the state account coordinates, project name
and region. `bootstrap.sh` generates `terraform.tfvars` files containing them.

CI needs the same values. The obvious move is to commit the tfvars — they contain
no credentials, only identifiers.

This repository is public.

## Decision

`*.tfvars` and `*.tfbackend` are gitignored. The generated files exist on the
operator's machine for local runs only.

CI receives the same values as **GitHub repository variables**, set by
`bootstrap.sh`, and consumed as `TF_VAR_*` environment variables in
`terraform.yml`. Backend coordinates are passed as `-backend-config` arguments
built from the same variables.

## Alternatives considered

**Commit the tfvars.** Genuinely tempting: they hold no secret, and committing
them would make the configuration fully self-describing and reviewable, which is
otherwise this repo's whole philosophy. Rejected because tenant, subscription and
Databricks account identifiers are reconnaissance material, and there is no
reason to publish them to the internet. The cost — configuration that is not
visible in the repo — is accepted reluctantly.

## Consequences

- Subscription, tenant and account identifiers are never published. GitHub
  variables are visible only to workflow runs and to people with repository
  access.
- Configuration is split across two places: `.tf` files in git, and variables in
  GitHub settings. Someone reading the repository cannot see which subscription
  it deploys to. This is a real legibility loss and the direct cost of the repo
  being public.
- The variables are repository-level rather than environment-level, because the
  `plan` job runs on `pull_request` and therefore cannot bind to an environment
  (ADR 0011). The `infra` environment still gates apply.
- A missing or misspelled variable surfaces as a Terraform "no value for required
  variable" error in CI rather than at configuration time. There is no schema
  validation on GitHub variables.
- `DATABRICKS_ACCOUNT_ID` must be set by hand after the account exists;
  `bootstrap.sh` prints the exact `gh variable set` command rather than leaving
  it as prose.
- If this repository were private, this decision should be revisited — committed
  tfvars would be strictly better for reviewability.
