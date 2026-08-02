# dlt-refresh-gitops

GitOps-style Databricks pipeline project: pipeline code, infrastructure and
full-refresh governance in one repo, one release process.

A full refresh is destructive. Here it is declared in a file, approved in a pull
request, executed by a service principal that no human can impersonate, and
recorded in a locked issue.

## Layout

```
├── databricks.yml                     # Asset Bundle: dev / tst / prd targets
├── src/
│   ├── pipeline.py                    # SDP pipeline (raw + incremental bronze table)
│   └── transformations.py             # pure transforms, unit-tested
├── tests/                             # local pytest suite (real local Spark)
├── governance/
│   └── refresh-requests.yaml          # declarative full-refresh requests
├── infra/                             # Azure + Databricks infrastructure (Terraform)
│   ├── bootstrap.sh                   # one-time local setup; everything else is CI
│   ├── teardown.sh                    # deletes everything, including what Terraform can't
│   ├── platform/                      # resource group, workspace, ADLS, access connector
│   └── databricks/                    # service principals, federation policies, catalogs, grants
├── docs/adr/                          # why every decision was made
└── .github/
    ├── CODEOWNERS                     # approval gate on refresh requests
    └── workflows/
        ├── terraform.yml              # infra/** → plan on PR, apply on merge to main
        └── deploy.yml                 # main → deploy tst; tag v* → deploy prd → gated refresh
```

## Environments

| Target | Catalog | Deployed by | Who can run the pipeline | Engineer data access |
|--------|---------|-------------|--------------------------|----------------------|
| `dev`  | `orders_dev` | engineers, locally | the deploying engineer | full |
| `tst`  | `orders_tst` | CI on merge to `main` or a release tag | engineers (`CAN_RUN`) | read |
| `prd`  | `orders_prd` | CI on a release tag (`X.Y.Z`) | nobody — service principal only | `BROWSE` only, no rows |

Each engineer gets their own prefixed schemas, volume and pipeline inside the
shared `orders_dev` catalog, so nobody collides and nobody needs an
infrastructure change to start work.

There are no credentials to share. Every identity authenticates by exchanging a
short-lived GitHub OIDC token, accepted only for this repository and one exact
GitHub Environment.

## The pattern

```
Engineer opens PR → pipeline code change and/or a refresh request
Merge to main     → unit tests → deploy to tst
Platform lead approves refresh requests (CODEOWNERS-enforced, no self-approval)
Tag X.Y.Z         → unit tests → deploy to tst → deploy to prd, then:
                      refresh-requests.yaml has an entry for this tag?
                        no  → refresh job is skipped, release ends here
                        yes → claim audit issue → full refresh → record outcome → lock
```

## Local development

Requires a JDK 17+ (PySpark 4). The test suite locates one automatically —
`JAVA_HOME`, then `~/.jdks/*`, then `/Library/Java/JavaVirtualMachines/*` — so no
shell configuration is needed.

```bash
uv sync          # create .venv with pyspark + pytest
uv run pytest    # run the transformation tests against a real local Spark
```

`src/transformations.py` holds the pure DataFrame logic and is what the tests
exercise; `src/pipeline.py` holds only the SDP table definitions, which need a
pipeline context and cannot run locally.

To deploy your own isolated copy:

```bash
databricks bundle deploy --target dev
```

## Requesting a refresh

Add an entry to `governance/refresh-requests.yaml`:

```yaml
- pipeline_key: "orders_pipeline"
  release_version: "2.14.0"
  reason: "Upstream schema fix, JIRA-4821"
```

Open a PR, get platform-lead approval, merge, tag `2.14.0`. Done.

## Setup

Infrastructure and identities are Terraform — see [infra/README.md](infra/README.md)
for the walkthrough. In short: run `infra/bootstrap.sh` once, grant the resulting
principal Databricks account admin, apply the two Terraform stages, then
`push-github-config.sh`. Everything after that is PR-driven.

Repo settings that are policy rather than plumbing, and so are left to you:

- Required reviewers on the `prd` and `infra` GitHub Environments.
- The `refresh-audit` issue label.
- Branch protection / org ruleset per `.github/CODEOWNERS`; engineers at
  Triage/Read so they cannot edit or unlock audit issues.
- `CODEOWNERS` pointed at your real team handle.

## Tearing it down

This is a learning project, and it is built to be deletable:

```bash
cd infra && ./teardown.sh
```

`terraform destroy` alone would leave the state account, the Entra application
and the GitHub Environments behind, because those precede Terraform and appear in
no state file. `teardown.sh` removes them too. It deletes production data without
resistance — [ADR 0018](docs/adr/0018-optimise-for-clean-teardown.md) explains
what safety that trades away and what to change for real use.

## Why it is built this way

Every significant decision — and the alternatives rejected along the way — is
recorded in **[docs/adr/](docs/adr/)**.

Start with [0015](docs/adr/0015-trunk-based-branching-and-release-flow.md) for how
work reaches production, [0016](docs/adr/0016-declarative-refresh-requests.md)
and [0017](docs/adr/0017-refresh-execution-safety-and-audit.md) for the refresh
governance, and [0008](docs/adr/0008-oidc-federation-no-stored-secrets.md) for why
there are no secrets anywhere.

## Known limits

- **A refresh outliving the 6-hour job limit is recorded as `OUTCOME UNKNOWN`.**
  The workflow waits for completion, but GitHub cancels the job at 360 minutes.
  The record says so honestly rather than claiming failure, and a re-tag is
  permitted.
- **The release job blocks for the duration of the refresh**, holding the
  `deploy` concurrency group. A long refresh delays other releases.
- **Idempotency relies on GitHub's search index**, which lags issue creation by
  seconds. Two release runs started within the same few seconds could both miss
  the other's audit issue; the `concurrency` group makes that unlikely rather
  than impossible.
- **`refresh-requests.yaml` is not schema-validated on PRs**, so a malformed
  entry surfaces at release time rather than at review time.

## Possible upgrades (not built yet, by design)

- Mirror audit events to Log Analytics (independent privilege boundary) or
  immutable blob storage (true WORM) if tamper-resistance requirements grow.
- Per-pipeline CODEOWNERS strictness for tier-1/sensitive tables.
- Validate `refresh-requests.yaml` schema on PRs, before the tag exists.
