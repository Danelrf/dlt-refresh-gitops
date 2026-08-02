# 17. Claim before acting, fail closed, and audit to a locked issue

Date: 2026-08-01

## Status

Accepted. The `--no-wait` and approver-capture consequences below were
superseded by [ADR 0019](0019-wait-for-completion-and-record-approver.md); the
three rules are unchanged.

## Context

ADR 0016 settled how a refresh is *approved*. This record covers how it is
*executed* and *recorded*, which is where the failure modes are.

A full refresh is destructive and irreversible. The dangerous scenarios are
running one twice, and running one without leaving a record — which are the same
scenario, because the record is what tells a re-run that the work is already
done.

## Decision

Three rules in the `refresh` job:

1. **Claim before acting.** The audit issue is created *before* the refresh is
   triggered, then updated with the outcome and locked.
2. **Idempotency fails closed.** If the workflow cannot determine whether a
   refresh already ran, it refuses rather than proceeding.
3. **The audit record is a locked GitHub issue**, labelled `refresh-audit`,
   carrying the reason, the tagger, the Databricks `update_id`, a link to the
   workflow run, and a SHA-256 integrity hash.

## Alternatives considered

**Recording the refresh after it succeeds**, which is the natural order.
Rejected: a crash between triggering and recording leaves production refreshed
with no audit record, and since deduplication keys off that record, the re-run
would refresh a second time. Claiming first can only produce the harmless
failure — a record with no refresh — which the finalise step then marks as
`FAILED to trigger`.

**A Delta table as the audit store.** Rejected: deletable by anyone with write
access to the catalog, and awkward to browse.

**Raw workflow run logs.** Rejected: they expire, and they are hard to search for
"was this pipeline ever refreshed".

## Consequences

- The finalise step runs with `if: always()`, so a claimed issue always ends up
  stating what actually happened rather than being abandoned mid-flight.
- Issues are locked on creation and engineers sit at Triage/Read, so the record
  cannot be edited or unlocked by the people it governs. The SHA-256 hash makes
  any edit by someone who *can* detectable.
- The `update_id` cross-references `system.access.audit`, which is the
  tamper-proof backstop. The GitHub issue is the browsable index; Databricks'
  own audit log is the authority.
- `--no-wait` means the record proves a refresh was *triggered*, not that it
  succeeded. Completion must be confirmed on the linked Databricks update. This
  is a known limitation, stated rather than hidden.
- Deduplication relies on GitHub's search index, which lags issue creation by
  seconds. Two release runs starting within the same few seconds could both miss
  the other's issue. The `concurrency` group makes this unlikely rather than
  impossible.
- The audit issue records the tagger via `github.actor`, not the pull request
  approver. Capturing the approver would need an additional API call and is not
  built.
