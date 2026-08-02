# 19. Wait for refresh completion, and record who approved it

Date: 2026-08-01

## Status

Accepted. Supersedes two consequences of
[0017](0017-refresh-execution-safety-and-audit.md).

## Context

ADR 0017 listed two weaknesses and accepted them:

- the refresh was triggered with `--no-wait`, so the record proved only that a
  refresh *started*;
- the record named the tagger (`github.actor`), not the person who approved the
  request.

Reviewing them together showed the first was not merely a weak record. It was a
correctness bug. The audit issue is created before acting (rule 1) and
deduplication keys off its existence (rule 2). So:

```
trigger succeeds → issue created → refresh FAILS in Databricks
  → release goes green → someone re-tags → dedupe finds the issue → SKIPPED
```

A failed refresh was permanently indistinguishable from a completed one, and the
fail-closed guarantee was false in exactly the case it existed for.

The second weakness matters because the tagger and the approver answer different
questions. Tagging ships a release; approving is the act that permitted
something destructive. Only the second is the authorisation.

## Decision

- Drop `--no-wait`. `databricks bundle run` blocks until the update finishes and
  exits non-zero on failure. The job carries `timeout-minutes: 360`.
- Resolve the approver: find the commit that last touched
  `governance/refresh-requests.yaml`, the pull request that carried it, and its
  approving reviewers. Record them in the audit issue and include them in the
  integrity hash.
- Deduplication ignores issues whose recorded outcome is `FAILED` or
  `OUTCOME UNKNOWN`, so a genuine failure can be retried by re-tagging.

## Alternatives considered

**A bounded poll** — trigger with `--no-wait`, then poll the update state and
record `COMPLETED`, `FAILED` or `still running`. Strictly more honest, since it
never misreports a long refresh. Rejected as more machinery than warranted.

**Keeping `--no-wait`, fixing only deduplication.** Rejected: it leaves the
record unable to state an outcome, which is most of what the record is for.

## Consequences

- The release job now blocks for the duration of the refresh and holds the
  `deploy` concurrency group while it does, so a long refresh delays other
  releases. This is the accepted cost.
- **One case still misreports**: if the refresh outlives the 6-hour job limit,
  GitHub cancels the run. The finalise step detects `cancelled` specifically and
  records `OUTCOME UNKNOWN` rather than `FAILED` — and because unknown does not
  block, a re-tag is permitted.
- An issue still reading "triggering" blocks a retry. That means a run died
  between claiming and finalising, so whether the refresh happened is genuinely
  unknown, and unknown must block.
- Retries create a second audit issue with the same title. Both are kept: the
  failures are part of the history.
- Resolving the approver needs `fetch-depth: 0` on checkout.
- If the entry was merged without a pull request, the record says
  `unknown (no pull request found)` rather than failing. Enforcement of the
  approval gate lives in branch protection; this only records. An "unknown" in
  the audit trail is itself the signal that something bypassed it.
