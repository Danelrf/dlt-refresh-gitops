# 6. Inject the pipeline source path from the bundle

Date: 2026-08-01

## Status

Accepted

## Context

`src/pipeline.py` originally hardcoded its Auto Loader source:

```python
SOURCE_PATH = "/Volumes/main/default/landing/orders"
```

Once each environment gained its own catalog (ADR 0002) and each engineer gained
their own prefixed schemas in `dev` (ADR 0004), a single literal path could not
be correct for more than one deployment.

## Decision

The bundle passes the path as pipeline configuration:

```yaml
configuration:
  source_path: "/Volumes/${var.catalog}/${resources.schemas.bronze.name}/${resources.volumes.landing.name}/orders"
```

and the pipeline reads it:

```python
SOURCE_PATH = spark.conf.get("source_path")
```

## Alternatives considered

**Keep the literal and vary it per target with a bundle variable substitution
inside the Python file.** Not possible without templating the source file itself,
which would mean the file in git is not the file that runs.

**Derive the path in Python from the pipeline's own catalog and schema.** Would
work, but it hardcodes the assumption that the landing volume always sits beside
the pipeline's output schema. Passing the path keeps that assumption in
`databricks.yml`, where the layout is already declared, rather than duplicating
it in code.

## Consequences

- A `dev` deployment reads from the deploying engineer's own volume. This is the
  point: with a hardcoded path, an engineer testing locally-authored changes
  would have been reading whatever the literal pointed at — potentially a shared
  or production landing area. The bundle now makes that structurally impossible.
- The three environments differ by configuration only; `pipeline.py` is identical
  across all of them, which is what makes a tst deployment meaningful as a
  rehearsal for prd.
- `spark.conf.get("source_path")` raises if the key is absent, so a
  misconfigured bundle fails at pipeline start rather than silently reading
  nothing.
- The path is visible in the pipeline's configuration in the Databricks UI, which
  makes "where is this reading from" answerable without opening the repo.
- `src/pipeline.py` remains untestable locally — it needs a pipeline context —
  which is unchanged from before and is why the pure logic lives in
  `src/transformations.py`.
