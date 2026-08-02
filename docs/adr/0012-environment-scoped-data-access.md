# 12. Environment-scoped data access; no production data for engineers

Date: 2026-08-01

## Status

Accepted. The destroy guardrail described here was later removed by
[ADR 0018](0018-optimise-for-clean-teardown.md); the access model is unchanged.

## Context

With a catalog per environment (ADR 0002), the `engineers` group needed a
privilege set in each. The starting position was inherited from the pipeline
permissions in `databricks.yml`: `CAN_RUN` in tst, `CAN_VIEW` in prd. Those govern
the *pipeline*; they say nothing about the *data*.

The requirement stated during review was that engineers should be able to deploy
freely and run their own work, while jobs owned by service principals — and the
data those jobs produce — should not be accessible to them.

## Decision

| | `orders_dev` | `orders_tst` | `orders_prd` |
|---|---|---|---|
| Deploy identity | each engineer, as themselves | `sp-*-tst` | `sp-*-prd` |
| Service principal | — | `ALL_PRIVILEGES` | `ALL_PRIVILEGES` |
| `engineers` | `ALL_PRIVILEGES` | `USE_CATALOG`, `USE_SCHEMA`, `SELECT`, `READ_VOLUME`, `EXECUTE` | `BROWSE` |

`dev` has no service principal at all: engineers deploy there as themselves from
their own machines.

## Alternatives considered

**`BROWSE` only in both tst and prd** — the strictest reading of "that data
shouldn't be accessible". Rejected because it makes tst nearly useless: an
engineer who deploys a pipeline to tst and cannot read what it produced has no
way to tell whether it worked, and would be pushed toward validating in prd
instead.

**`SELECT` in tst and prd both**, treating the governance boundary as purely
about who may *trigger* a refresh rather than who may read. Rejected: governing
the trigger while leaving the output freely readable is a half-measure, and
production data is the thing actually worth protecting.

## Consequences

- `BROWSE` in prd lets engineers see that objects exist and inspect lineage
  without reading a single row. Combined with `CAN_VIEW` on the pipeline, they
  can debug a production run — schema, table names, run history, failure
  messages — without production data.
- `ALL_PRIVILEGES` in `orders_dev` includes `CREATE_SCHEMA`, which is exactly
  what lets `databricks bundle deploy --target dev` create each engineer's
  personally-prefixed schemas and volume without a Terraform change (ADR 0004).
- Grants are applied at catalog level and inherit downward, so this table is the
  complete data access model — including for objects that do not exist yet.
- The whole policy is one `environments` map in `databricks/variables.tf`.
  Changing who can read prd is a reviewable diff in a single place rather than a
  console action.
- Group membership is deliberately *not* in Terraform. The `engineers` group is
  created and granted here; who belongs to it is managed in the account console,
  so adding a colleague does not require an infrastructure pull request.
- Nothing prevents an engineer from copying tst data somewhere less governed.
  This model constrains reads, not exfiltration.
