# 5. Bronze and silver schemas, with landing as a volume in bronze

Date: 2026-08-01

## Status

Accepted

## Context

Each environment's catalog needed a layout. The pipeline in this repo writes one
raw table and one cleaned table, and it ingests files with Auto Loader, so it
needs somewhere for those files to arrive.

The first draft used a `bronze` schema for pipeline output and a separate
`landing` schema whose only content was an `orders` volume.

## Decision

Two schemas per catalog, `bronze` and `silver`. The Auto Loader landing area is a
single volume named `landing` inside `bronze`, with one subdirectory per source.

The pipeline reads `/Volumes/<catalog>/bronze/landing/orders`.

## Alternatives considered

**A dedicated `landing` schema holding the volume.** This was the original draft.
The argument for it was that a raw file drop zone and a set of curated tables are
different kinds of thing and could carry different grants. Rejected as an
over-separation: unstructured arrivals belong to the raw layer conceptually, not
beside it, and a schema containing exactly one volume is a container that earns
nothing. Splitting it would also have doubled the number of objects the bundle
creates per engineer in `dev`.

**A volume per source** (`landing_orders`, `landing_customers`, …). Not adopted;
one volume with a subdirectory per source scales the same way without adding a
Databricks object each time a source is added.

## Consequences

- `silver` exists from the start even though nothing writes to it yet. It is
  declared so that downstream modelling has an obvious home and does not end up
  polluting `bronze` by default. It costs nothing to declare an empty schema.
- Because both schemas and the volume are bundle-owned (ADR 0004), each engineer
  in `dev` gets their own prefixed `bronze`, `silver` and `landing`. Grants
  inherit from `orders_dev`, so no per-engineer grant management is needed.
- Grants on the volume come from the catalog, so `READ_VOLUME` in tst and none in
  prd follow automatically from ADR 0012 without a separate volume grant
  resource.
- The volume is `MANAGED`, so its files live under the catalog's `storage_root`
  in that environment's own container. Nothing needs to know a storage path.
- Adding a third layer (`gold`) is one entry in `databricks.yml`.
