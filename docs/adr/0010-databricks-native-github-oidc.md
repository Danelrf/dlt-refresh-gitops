# 10. Use Databricks-native `github-oidc` for the bundle hop

Date: 2026-08-01

## Status

Accepted

## Context

ADR 0008 committed to secretless authentication for both hops. Hop 1 (Terraform
to Azure ARM) is settled: `azurerm` has supported `ARM_USE_OIDC` for years.

Hop 2 — GitHub Actions to the Databricks workspace, for `bundle deploy` and
`bundle run` — had two plausible routes, and the choice was explicitly deferred
until it could be verified against current documentation rather than assumed.

## Decision

Use Databricks OAuth token federation. The workflow sets:

```yaml
DATABRICKS_AUTH_TYPE: github-oidc
DATABRICKS_HOST: ${{ vars.DATABRICKS_HOST }}
DATABRICKS_CLIENT_ID: ${{ vars.DATABRICKS_CLIENT_ID }}
```

with `permissions: id-token: write`. `databricks/setup-cli` performs the token
exchange. A `databricks_service_principal_federation_policy` per environment
declares which OIDC subject is accepted.

## Alternatives considered

**`azure/login@v2` with OIDC, then the Databricks CLI using `azure-cli` auth.**
Attractive because it reuses one identity mechanism (Entra federation) for both
hops and needs no Databricks account-level configuration at all — no account ID,
no account admin, no federation policies.

Rejected after checking: the Databricks CLI has open issues specifically about
**`bundle` commands** failing under federated Azure credentials —
[#1722](https://github.com/databricks/cli/issues/1722) ("CLI authenticates with
azure-cli, but bundle deployment does not"),
[#4047](https://github.com/databricks/cli/issues/4047) and
[#4226](https://github.com/databricks/cli/issues/4226) (bundle deploy fails with
`azure-devops-oidc`). Plain CLI calls work; bundle deploys are the exact thing
that does not. Since bundle deploy is the whole job, this route was not viable.

The Databricks documentation independently presents `github-oidc` as the
supported path for bundle deployments.

## Consequences

- Requires the Databricks **account ID** and an account-level Terraform provider,
  which is part of why the configuration is split in two (ADR 0003).
- Requires the Terraform runner to be a Databricks **account admin** — a manual
  bootstrap step that cannot be automated, because granting account authority is
  itself an account-authority action.
- Federation policies are manageable in Terraform
  (`databricks_service_principal_federation_policy`, confirmed present in
  provider 1.123.0), so the trust relationships are reviewable diffs rather than
  console clicks.
- The `audiences` field is set to the account ID, matching the Databricks default
  rather than relying on it implicitly.
- Each service principal supports at most 20 federation policies; we use one
  each, so the limit is not a concern.
- `azure/login` is still used in `terraform.yml`, but only to give the
  `databricks` Terraform provider an Azure credential — a separate concern from
  the CLI hop described here.
