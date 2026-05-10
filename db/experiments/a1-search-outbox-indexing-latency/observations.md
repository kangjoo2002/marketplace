# A-1 Search Outbox Indexing Latency Observations

## Current Status

This PR adds measurement infrastructure only.

No local smoke measurement was executed for this PR, and no latency numbers are recorded here.

## What Was Added

- Persisted SQL measurement for `total_indexing_lag_ms = processed_at - created_at`.
- Queue/status counts: `pending`, `processing`, `failed`, `done`.
- `oldest_pending_age_ms`.
- Retry count distribution.
- Relay structured timing log for decomposed latency:
  - `queueWaitMs`
  - `sourceDocumentLoadMs`
  - `openSearchWriteMs`
  - `outboxStateTransitionMs`
  - `relayProcessingMs`

## Why No Numbers Are Listed

No command was run that processes a controlled local smoke dataset and captures the SQL/log output as a pass artifact.

The repository now has the query and relay timing log needed to produce those numbers in a later local synthetic run. Any future numbers should be labeled as local smoke results, not production SLO/SLA.

## Limitations

- `total_indexing_lag_ms` is persisted through existing outbox timestamps.
- Per-step breakdown is emitted as runtime log output, not persisted in new database columns.
- The SQL query cannot derive `sourceDocumentLoadMs`, `openSearchWriteMs`, or `outboxStateTransitionMs` from existing outbox columns.
- No Bulk Indexing, tuning, k6 benchmark, or production readiness claim is included.

## Recommended Next Step

Run a controlled local single-document relay smoke, capture `product_search_outbox_indexing_latency` log lines, and run `measure-indexing-lag.sql` against the same window or `smokeRun` marker.
