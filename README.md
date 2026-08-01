# dlt-refresh-gitops

GitOps-style Databricks pipeline project: pipeline code and full-refresh
governance in one repo, one release process.

## Layout

```
├── databricks.yml                     # Asset Bundle: dev / tst / prd targets
├── src/
│   ├── pipeline.py                    # SDP pipeline (raw + incremental bronze table)
│   └── transformations.py             # pure transforms, unit-tested
├── tests/                             # local pytest suite (real local Spark)
├── pipelines/
│   └── refresh-requests.yaml          # declarative full-refresh requests
└── .github/
    ├── CODEOWNERS                     # approval gate on refresh requests
    └── workflows/
        ├── deploy-tst.yml             # merge to main → test → deploy tst
        └── release.yml                # tag v* → deploy prd → gated refresh → audit issue
```

## Environments

| Target | Mode | Deployed by | Who can run the pipeline |
|--------|------|-------------|--------------------------|
| `dev`  | `development` | engineers, locally | the deploying engineer (resources are per-user prefixed) |
| `tst`  | `production`  | CI on merge to `main` | engineers (`CAN_RUN`) |
| `prd`  | `production`  | CI on tag `v*` | nobody — service principal only |

`tst` uses `mode: production` despite the name: that is what gives stable,
unprefixed resource names, which a shared environment needs. `mode: development`
prefixes everything with the deploying user and is for `dev` only.

Host and service-principal credentials come from **GitHub Environments** named
`tst` and `prd`, so the two never share credentials and `prd` can carry
deployment protection rules as a second gate.

## The pattern

```
Engineer opens PR → pipeline code change and/or a refresh request
Merge to main     → unit tests → deploy to tst
Platform lead approves refresh requests (CODEOWNERS-enforced, no self-approval)
Tag vX.Y.Z        → deploy to prd, then:
                      refresh-requests.yaml has an entry for this tag?
                        no  → refresh job is skipped, release ends here
                        yes → claim audit issue → full refresh → record outcome → lock
```

Analogy: this is the Flyway/Liquibase migration pattern applied to pipeline
refreshes — the requests file plays the role of migration scripts (declared
intent, version-controlled, PR-reviewed) and the locked audit issues play the
role of `flyway_schema_history` (execution record kept outside the files,
checksummed against them).

## Design decisions

- **Code + refresh intent version together.** A release that changes the
  pipeline logic AND requires a refresh is one PR, one review, one tag —
  they can't drift apart.
- **The requests file declares intent only.** No status fields, no CI
  write-back. The repo answers "what was approved and by whom" (git/PR
  history); the audit issues answer "what actually executed and when".
  It is called `refresh-requests.yaml` rather than a "changelog" precisely
  because it describes the future, not the past.
- **Refresh is a separate, skippable job.** No entry for the tag means the
  `refresh` job never starts — visible as a skipped job, not a silent no-op.
  Two entries for one tag is a hard failure rather than a guess.
- **Claim before acting.** The audit issue is created *before* the refresh is
  triggered, then updated with the outcome and locked. A crash mid-run can
  leave a refresh unrecorded otherwise — and since idempotency keys off that
  record, the re-run would refresh twice.
- **Audit record = locked GitHub issue**, not a Delta table (deletable, hard
  to browse) and not raw run logs (hard to find). Locked on creation,
  searchable by label, carries a SHA-256 integrity hash (edits become
  detectable) and the Databricks `update_id` (cross-reference to
  `system.access.audit` as the tamper-proof backstop).
- **Idempotency fails closed.** If the workflow cannot determine whether a
  refresh already ran, it refuses rather than risking a second destructive
  refresh.
- **Refresh reasons are never interpolated into shell.** They are PR-authored
  text reaching a runner that holds the prd service principal secret, so they
  travel as environment variables only.
- **Execution identity is a service principal.** The `prd` target sets
  `run_as` to the SP and grants engineers view-only; the workflow
  authenticates with SP OAuth credentials. No human holds trigger permission
  in prd. In `tst` engineers keep `CAN_RUN` — that is what tst is for.
- **Bundle resource key, not UUID.** Requests reference `pipeline_key` (e.g.
  `orders_pipeline`) and the workflow resolves it via the bundle — no
  hardcoded pipeline IDs to keep in sync.
- **No parallel workflow_dispatch path.** Releases are on-demand, so the PR
  path is fast enough for ad-hoc needs. Break-glass for "the release pipeline
  itself is broken": run `databricks bundle run <key> --target prd
  --full-refresh-all` manually with SP credentials, then retroactively file
  the audit issue.

## Local development

Requires a JDK 17+ (PySpark 4). The test suite locates one automatically —
`JAVA_HOME`, then `~/.jdks/*`, then `/Library/Java/JavaVirtualMachines/*` —
so no shell configuration is needed.

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

## Setup

1. **Service principals** in your Databricks account, one per environment;
   note their application IDs.
2. **GitHub Environments** named `tst` and `prd`, each with:
   - `DATABRICKS_HOST` (var) — e.g. `https://adb-xxxx.azuredatabricks.net`
   - `SP_CLIENT_ID` (var) — service principal application ID
   - `SP_CLIENT_SECRET` (secret) — SP OAuth secret

   Add required reviewers to `prd` if you want a deployment gate on top of
   CODEOWNERS.
3. **GitHub settings**: create the `refresh-audit` label; branch protection /
   org ruleset per `.github/CODEOWNERS` comments; engineers at Triage/Read so
   they cannot edit or unlock audit issues.
4. Update `CODEOWNERS` with your real team handle, and `src/pipeline.py`
   with your actual source path/schema.
5. First deploy: `databricks bundle deploy --target dev` locally to validate,
   then merge to main for tst, then tag a release for prd.

## Requesting a refresh

Add an entry to `pipelines/refresh-requests.yaml`:

```yaml
- pipeline_key: "orders_pipeline"
  release_version: "v2.14.0"
  reason: "Upstream schema fix, JIRA-4821"
```

Open a PR, get platform-lead approval, merge, tag `v2.14.0`. Done.

## Known limits

- **`--no-wait` means "triggered", not "succeeded".** The audit issue records
  that a refresh started; completion must be confirmed on the Databricks
  update it links to.
- **Idempotency relies on GitHub's search index**, which lags issue creation
  by seconds. Two release runs started within the same few seconds could both
  miss the other's audit issue; the `concurrency` group makes that unlikely
  rather than impossible.

## Possible upgrades (not built yet, by design)

- Mirror audit events to Log Analytics (independent privilege boundary) or
  immutable blob storage (true WORM) if tamper-resistance requirements grow.
- Capture the PR approver identity in the audit issue via the GitHub API
  (currently records the tagger via `github.actor`).
- Per-pipeline CODEOWNERS strictness for tier-1/sensitive tables.
- Validate `refresh-requests.yaml` schema on PRs, before the tag exists.
