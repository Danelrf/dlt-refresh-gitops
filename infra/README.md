# infra

Azure and Databricks infrastructure for this repo, as Terraform.

Applied by CI, not by people: `.github/workflows/terraform.yml` plans on every PR
touching `infra/**` and applies on merge to `main`. The one exception is
`bootstrap.sh`, which runs once on a laptop to create the things that cannot
create themselves.

## Structure

```
infra/
├── bootstrap.sh              one-time local setup
├── grant-databricks-admin.sh makes the runner a Databricks account admin
├── push-github-config.sh     fills in the tst/prd GitHub Environments
├── platform/                 azurerm only — resource group, workspace,
│                             ADLS Gen2 + one container per environment,
│                             Access Connector + its storage role
└── databricks/               databricks only — account service principals,
                              federation policies, workspace assignment,
                              engineers group, catalogs, external locations, grants
```

Stage 2 reads stage 1's outputs through `terraform_remote_state`, so they are
applied in that order. Why they are separate at all:
[ADR 0003](../docs/adr/0003-split-terraform-into-two-stages.md).

Terraform stops at the catalog — schemas, volumes and pipelines belong to
`databricks.yml`:
[ADR 0004](../docs/adr/0004-terraform-owns-catalogs-bundle-owns-schemas.md).

## Identity model

```
Entra ID tenant
└── sp-<project>-terraform          Contributor + RBAC Administrator on the
                                    subscription; Databricks account admin.
                                    Authenticates by GitHub OIDC federation.

Databricks account
├── sp-<project>-tst                federation policy:
│                                     repo:<owner>/<repo>:environment:tst
└── sp-<project>-prd                federation policy:
                                      repo:<owner>/<repo>:environment:prd
```

No secrets exist anywhere in this design — not in GitHub, not in Terraform
state, not on a laptop. A job that does not declare `environment: prd` cannot
obtain prd credentials, because the token it is able to mint carries the wrong
subject.

See [ADR 0008](../docs/adr/0008-oidc-federation-no-stored-secrets.md),
[ADR 0009](../docs/adr/0009-databricks-managed-service-principals.md),
[ADR 0011](../docs/adr/0011-github-environments-as-identity-boundary.md).

## Access model

| | `orders_dev` | `orders_tst` | `orders_prd` |
|---|---|---|---|
| Deploy identity | each engineer, as themselves | `sp-*-tst` | `sp-*-prd` |
| SP privileges | — | `ALL_PRIVILEGES` | `ALL_PRIVILEGES` |
| `engineers` privileges | `ALL_PRIVILEGES` | `USE_CATALOG`, `USE_SCHEMA`, `SELECT`, `READ_VOLUME`, `EXECUTE` | `BROWSE` |

Grants are set once per catalog and inherit downward, so objects the bundle has
not created yet are already covered. The whole policy is the `environments` map
in `databricks/variables.tf` —
[ADR 0012](../docs/adr/0012-environment-scoped-data-access.md).

## First-time setup

```bash
cd infra
./bootstrap.sh
```

Creates the state storage account, the Terraform runner service principal and its
federated credentials, the Azure role assignments, and the `infra` GitHub
Environment. The Databricks account itself does not exist yet — it is created
as a side effect of the first workspace — so the remaining steps run in this
order:

1. Apply stage 1, which creates that workspace (and with it, the account):
   ```bash
   cd platform && terraform init -backend-config=../backend.platform.tfbackend && terraform apply
   ```
2. Visit <https://accounts.azuredatabricks.net> once as an Entra ID **Global
   Administrator**. Databricks auto-promotes the first Global Admin who logs
   in there to Databricks account admin — this is the one truly manual step;
   it's how the first admin comes to exist at all. Copy the account ID while
   you're in there (top-right user menu).
3. Make the Terraform runner a Databricks **account admin** too, so CI can
   manage the account from here on:
   ```bash
   cd .. && DATABRICKS_ACCOUNT_ID=<account-id> ./grant-databricks-admin.sh
   ```
   This signs you in as the admin from step 2 and does the rest —
   registering the service principal and granting the role — via the
   Accounts Access Control API instead of more console clicking. It also
   prints the `DATABRICKS_ACCOUNT_ID` commands you still need to run by hand:
   ```bash
   gh variable set DATABRICKS_ACCOUNT_ID --repo <owner>/<repo> --body <account-id>
   ```
   and the same value in `databricks/terraform.tfvars` for local runs.

Then the first apply, locally:

```bash
cd databricks && terraform init -backend-config=../backend.databricks.tfbackend && terraform apply
cd .. && ./push-github-config.sh
```

After that, everything goes through PRs.

## Day-to-day

Change a `.tf` file, open a PR. The plan appears in the job summary. Merge, and
`terraform.yml` applies it.

To read state locally, you need the backend config `bootstrap.sh` wrote and
`Storage Blob Data Contributor` on the state account, which it also granted you.

## Tearing it all down

```bash
cd infra
./teardown.sh
```

`terraform destroy` on its own is not enough: `bootstrap.sh` created the state
account, the Entra application, its role assignments and the GitHub
Environments, and none of those appear in any Terraform state. `teardown.sh`
destroys both stages in reverse order, then removes those too, deleting the
state account last because everything before it needed the state.

It requires you to type the project name to confirm, and it deletes production
data without ceremony — see
[ADR 0018](../docs/adr/0018-optimise-for-clean-teardown.md).

## Gotchas

- **Unity Catalog metastore.** Stage 2 assumes the workspace has one assigned.
  Databricks auto-provisions one per region for accounts created since late 2023.
  If yours predates that, create and assign a metastore once at account level;
  the config then works unchanged.
- **Node type availability.** The pipeline uses classic compute, so `location`
  must be a region that offers the `node_type_id` set in `databricks.yml`
  (`Standard_D4ds_v5` by default).
- **`force_destroy` defaults to `true`, including prd.** This is a learning
  project and being able to delete it matters more than being protected from
  deleting it. For anything real, set `force_destroy = false` in
  `databricks/variables.tf` — see
  [ADR 0018](../docs/adr/0018-optimise-for-clean-teardown.md).
- **Anyone who can open a PR can run `terraform plan` as the runner.** Plan is
  read-only, but it executes provider code with the runner's identity. Hence the
  single-subscription scope, and required reviewers on `infra`.
- **Fork PRs cannot plan.** GitHub withholds `id-token` from forked-repo
  workflows. Expected.
- **The runner holds `Role Based Access Control Administrator` at subscription
  scope**, because `platform/main.tf` creates a role assignment. Narrowing this
  to the resource group is the obvious hardening step for a client setting.
