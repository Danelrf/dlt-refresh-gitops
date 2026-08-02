# 4. Terraform owns catalogs; the Asset Bundle owns schemas and pipelines

Date: 2026-08-01

## Status

Accepted

## Context

The first draft of the Terraform had it declaring catalogs, schemas (`bronze`,
`silver`) and the landing volume. That put Terraform and the Databricks Asset
Bundle in the same territory: a DAB pipeline creates its own target schema as
part of `bundle deploy`.

The question raised during review was whether Terraform should manage schemas at
all, or stop at the catalog.

## Decision

Terraform owns the catalog and everything below it in the security stack:
storage, external locations, storage credential, identities, and the grants on
each catalog. It stops there.

The Asset Bundle (`databricks.yml`) owns the application artifacts: `bronze` and
`silver` schemas, the `landing` volume, and the pipeline.

## Alternatives considered

**Terraform declares schemas and volumes too.** Rejected for two concrete
failures. First, ownership conflict: the bundle creates its pipeline's target
schema on deploy, so both tools would claim the same object and each would see
the other's work as drift. Second, and more damaging, it would break the `dev`
environment entirely. `mode: development` prefixes every bundle resource with the
deploying engineer's name, so each engineer gets their own schemas and volume
inside `orders_dev`. If Terraform declared the schema set, an engineer could not
create anything of their own without opening a Terraform pull request — which
defeats the purpose of having a dev environment.

## Consequences

- The boundary is legible: catalogs are a security boundary, schemas are
  application artifacts. A reviewer can tell which tool owns an object by asking
  which of those two things it is.
- Grants are applied once per catalog and inherit downward to every schema,
  table and volume — including objects the bundle has not created yet. The whole
  access model is therefore three `databricks_grants` resources, and there is no
  window in which a newly created table is ungoverned.
- Adding a schema is a `databricks.yml` change reviewed by whoever reviews
  pipeline code, not an infrastructure change. This is the correct blast radius
  for the action.
- Terraform cannot place a volume inside a bundle-owned schema, which is what
  forced the landing volume into the bundle as well (ADR 0005).
- The catalog is created with `storage_root` pointing at that environment's
  external location, so managed tables and volumes land in the right container
  automatically without any per-schema configuration.
