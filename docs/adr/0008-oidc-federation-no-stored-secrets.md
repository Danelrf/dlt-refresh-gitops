# 8. Authenticate CI by OIDC federation; store no secrets

Date: 2026-08-01

## Status

Accepted

## Context

Once infrastructure moved into CI (ADR 0007), there were two authentication hops
to solve:

1. GitHub Actions to Azure ARM, for Terraform.
2. GitHub Actions to the Databricks workspace, for `bundle deploy` and
   `bundle run --full-refresh-all`.

The existing workflow used service principal client secrets held in GitHub
Environment secrets, with a rotation schedule.

## Decision

Both hops authenticate by workload identity federation. No client secret is
stored in GitHub, in Terraform state, or on any machine.

Hop 1 uses an Entra federated credential with `ARM_USE_OIDC`. Hop 2 uses
Databricks OAuth token federation (ADR 0010).

## Alternatives considered

**Client secrets in GitHub Environment secrets**, the pre-existing design. A
secret is a bearer credential: whoever holds it *is* the principal, from any
machine, until it expires. It sits at rest for its whole lifetime and someone
owns a rotation calendar that, if missed, breaks production deploys.

**OIDC for Terraform, client secret for Databricks.** Offered as the
lower-risk option because hop 1 via `ARM_USE_OIDC` is long-settled while hop 2
needed verification. Not adopted, but only after confirming hop 2 against current
Databricks documentation; had that verification failed, this was the fallback and
would have required no rework of the Terraform half.

## Consequences

- The security gain is not merely "no secret to leak". It is that the credential
  is **bound to the context that produced it**. GitHub mints a short-lived JWT
  describing the repository, workflow and environment of that specific run; the
  trust policy accepts only one exact subject. A token minted by a pull request
  cannot satisfy a policy requiring `environment:prd`. A leaked client secret has
  no such constraint.
- This matters most for the prd identity, which is the one able to issue a
  destructive full refresh.
- Nothing needs rotating, so the `azuread_application_password` resources, the
  `time_rotating` rotation driver, the `secret_expiry` output and the
  stdin-piping secret-push script were all deleted. `push-github-config.sh` now
  sets only non-secret variables.
- Every job doing either hop needs `permissions: id-token: write`. Jobs that do
  not (unit tests, the refresh-request check) deliberately do not have it.
- Credentials cannot be used outside GitHub Actions at all. Break-glass
  procedures that assumed a human could authenticate as the prd principal from a
  laptop no longer work — an account admin must intervene instead. This is a
  deliberate tightening, and it is a real operational constraint.
- GitHub is now a trusted identity provider for the Azure tenant and the
  Databricks account. Compromise of the repository's Actions configuration is
  compromise of those trust relationships, which is what makes branch protection
  and environment reviewers load-bearing rather than cosmetic.
