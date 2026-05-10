# A-1 Search Outbox Indexing Latency Baseline

## Purpose

This experiment adds a baseline for observing latency in the `search_outbox -> relay -> OpenSearch` indexing path.

Indexing latency means the time from a product change event being captured in `search_outbox` until the relay finishes the corresponding OpenSearch write/delete and records the final outbox state.

## Metrics

Persisted SQL metrics use existing `search_outbox` timestamps:

- `total_indexing_lag_ms = processed_at - created_at` for `DONE` rows
- `pending_count`
- `processing_count`
- `failed_count`
- `done_count`
- `oldest_pending_age_ms`
- retry count distribution

Total lag alone is insufficient because it combines queue wait and relay work. The relay now emits a structured timing log for each processed event:

```text
product_search_outbox_indexing_latency eventId=... aggregateId=... eventType=... resultStatus=... queueWaitMs=... sourceDocumentLoadMs=... openSearchWriteMs=... outboxStateTransitionMs=... relayProcessingMs=...
```

Breakdown model:

- `queueWaitMs`: claim time minus outbox `created_at`
- `sourceDocumentLoadMs`: DB source document load time
- `openSearchWriteMs`: OpenSearch upsert/delete call time
- `outboxStateTransitionMs`: mark `DONE`, `PENDING`, or `FAILED` time
- `relayProcessingMs`: time after claim while the relay handles the event

The schema is unchanged. Missing persisted breakdown timestamps are not fabricated.

## SQL Usage

Run against local PostgreSQL with an explicit window or `smokeRun` marker:

```powershell
Get-Content db\experiments\a1-search-outbox-indexing-latency\sql\measure-indexing-lag.sql |
  docker compose exec -T postgres psql -U readpath -d readpath_lab -q -t -A `
    -v window_start='2026-05-10T00:00:00Z' `
    -v window_end='2026-05-10T01:00:00Z'
```

For namespaced smoke data:

```powershell
Get-Content db\experiments\a1-search-outbox-indexing-latency\sql\measure-indexing-lag.sql |
  docker compose exec -T postgres psql -U readpath -d readpath_lab -q -t -A `
    -v smoke_run='local-smoke-run-id'
```

## Non-Goals

This is not Bulk Indexing, batch size tuning, k6 benchmarking, OpenSearch tuning, production monitoring, or a production SLO/SLA claim.

## Next Step

Use the SQL output plus relay timing logs in a controlled local smoke run to establish a single-document indexing latency baseline before deciding whether Bulk Indexing is needed.
