# Architecture decision records

Why this project is built the way it is. Each record states the context, the
decision, the alternatives that were actually weighed, and what the decision
costs.

The READMEs describe *what* exists and how to use it. These describe *why*, and
what was given up.

| # | Decision |
|---|----------|
| [0001](0001-provision-infrastructure-with-terraform.md) | Provision infrastructure with Terraform |
| [0002](0002-single-workspace-catalog-per-environment.md) | One workspace, one catalog per environment |
| [0003](0003-split-terraform-into-two-stages.md) | Split Terraform into platform and databricks stages |
| [0004](0004-terraform-owns-catalogs-bundle-owns-schemas.md) | Terraform owns catalogs; the Asset Bundle owns schemas and pipelines |
| [0005](0005-medallion-schemas-landing-volume-in-bronze.md) | Bronze and silver schemas, with landing as a volume in bronze |
| [0006](0006-inject-pipeline-source-path-from-bundle.md) | Inject the pipeline source path from the bundle |
| [0007](0007-apply-infrastructure-from-ci.md) | Apply infrastructure from CI, not from laptops |
| [0008](0008-oidc-federation-no-stored-secrets.md) | Authenticate CI by OIDC federation; store no secrets |
| [0009](0009-databricks-managed-service-principals.md) | Databricks-managed service principals for the deploy identities |
| [0010](0010-databricks-native-github-oidc.md) | Use Databricks-native `github-oidc` for the bundle hop |
| [0011](0011-github-environments-as-identity-boundary.md) | GitHub Environments are the identity boundary |
| [0012](0012-environment-scoped-data-access.md) | Environment-scoped data access; no production data for engineers |
| [0013](0013-remote-state-and-bootstrap-script.md) | Remote Terraform state in Azure Blob, created by a bootstrap script |
| [0014](0014-terraform-inputs-in-github-variables.md) | Terraform inputs live in GitHub variables, not committed tfvars |
| [0015](0015-trunk-based-branching-and-release-flow.md) | Trunk-based branching: `main` deploys tst, `v*` tags deploy prd |
| [0016](0016-declarative-refresh-requests.md) | Full refreshes are declared in `refresh-requests.yaml` |
| [0017](0017-refresh-execution-safety-and-audit.md) | Claim before acting, fail closed, and audit to a locked issue |
| [0018](0018-optimise-for-clean-teardown.md) | Optimise for clean teardown — amends 0012 and 0013 |
| [0019](0019-wait-for-completion-and-record-approver.md) | Wait for refresh completion, and record who approved it — supersedes part of 0017 |

Note that this is a **learning project**, and
[0018](0018-optimise-for-clean-teardown.md) trades away some production-grade
safety to keep it fully deletable. Read it before reusing any of this for
something real.

## Reading order

If you are new to the repository, the shortest path to understanding it:

- **How work reaches production** — 0015, then 0016 and 0017.
- **How the infrastructure is built** — 0001, 0003, 0004.
- **Why there are no secrets anywhere** — 0007, 0008, 0011, then 0009 and 0010
  for the identity details.
- **Who can see what** — 0002 and 0012.

## Adding a record

Number sequentially, keep it under 500 words, and record only alternatives that
were genuinely considered. A record that lists no cost is not finished — every
decision here gave something up, and the next person needs to know what.

Records are immutable once accepted. If a decision changes, add a new record and
mark the old one superseded.
