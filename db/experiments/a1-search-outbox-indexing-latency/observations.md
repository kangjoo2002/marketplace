# A-1 Search Outbox Indexing Latency Observations

## Current Status

This experiment currently has measurement infrastructure, a JUnit relay instrumentation smoke, and a real local PostgreSQL + OpenSearch single-document baseline result.

The Bulk comparison baseline is the local PostgreSQL + OpenSearch result:

```text
results/single-index-baseline-local-20260510-2035/
```

The JUnit artifact is intentionally downgraded to relay instrumentation smoke:

```text
results/relay-instrumentation-smoke-junit-20260510/
```

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
- Reproducible single-document baseline procedure:
  - `single-document-baseline.md`
  - `results/<run-id>/summary.md`
  - `results/<run-id>/indexing-lag-summary.json`
  - `results/<run-id>/relay-log-sample.txt`
- Local baseline runner:
  - `scripts/run-single-index-baseline.ps1`

## Measurement Method

The PR #33 Bulk comparison baseline is a local synthetic PostgreSQL + OpenSearch smoke:

- disposable PostgreSQL is started with `POSTGRES_DB=marketplace`, `POSTGRES_USER=marketplace`, and `POSTGRES_PASSWORD=marketplace`
- the runner connects with `psql -U marketplace -d marketplace`
- the runner initializes the minimal `products`, `product_options`, and `search_outbox` schema before loading smoke data
- source rows are inserted into local PostgreSQL
- `search_outbox` rows are inserted with a `smokeRun` marker
- rows are claimed with `FOR UPDATE SKIP LOCKED`
- source documents are loaded from PostgreSQL
- each claimed event performs one OpenSearch document write
- outbox rows are marked `DONE`
- `measure-indexing-lag.sql` records total lag and queue/status counts

The JUnit artifact validates relay timing instrumentation only. CountingIndexWriter-based values must not be used as the single-index OpenSearch baseline.

## Baseline Result

Committed local baseline:

```text
results/single-index-baseline-local-20260510-2035/
```

Summary:

| metric | value |
|---|---:|
| event count | 100 |
| DONE events | 100 |
| FAILED events | 0 |
| pending count | 0 |
| processing count | 0 |
| total processing time ms | 32806 |
| total indexing lag p50 ms | 16805.131 |
| total indexing lag p95 ms | 31172.09755 |
| total indexing lag p99 ms | 32508.988720000005 |
| total indexing lag max ms | 32816.4550000 |
| OpenSearch write/delete call count | 100 |
| relay timing line count | 100 |

## 2026-05-10 — Queue wait attribution

Experiment conditions:

- Environment: local synthetic / local PostgreSQL + OpenSearch smoke
- eventCount: 100
- workerCount: 1
- Cases: batchSize 20 and batchSize 100

| batchSize | totalProcessingTimeMs | totalIndexingLagMs p50 | totalIndexingLagMs p95 | totalIndexingLagMs p99 | totalIndexingLagMs max | queueWaitMs p50 | queueWaitMs p95 | queueWaitMs p99 | queueWaitMs max | sourceDocumentLoadMs p50/p95/p99/max | openSearchWriteMs p50/p95/p99/max | outboxStateTransitionMs p50/p95/p99/max | relayProcessingMs p50/p95/p99/max | OpenSearch write/delete calls | relay timing log lines |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|---|---|---|---:|---:|
| 20 | 82422 | 45802.308000000005 | 79457.4898 | 81886.11067000001 | 82576.4050000 | 36295 | 70085 | 70085 | 70085 | 317 / 634 / 1233 / 1574 | 62 / 120 / 198 / 250 | 327 / 626 / 798 / 1571 | 720 / 1267 / 1976 / 2567 | 100 | 100 |
| 100 | 56695 | 29800.853000000003 | 54099.1885 | 56219.62305 | 56711.2620000 | 219 | 219 | 219 | 219 | 251 / 384 / 463 / 593 | 59 / 77 / 96 / 112 | 230 / 356 / 439 / 696 | 547 / 775 / 900 / 1065 | 100 | 100 |

Minimal interpretation: batchSize 100 reduced `queueWaitMs` in this local smoke run, while `totalIndexingLagMs` remained above zero.

Raw measurement results:

```text
db/experiments/a1-search-outbox-indexing-latency/results/queue-wait-attribution-local-20260510-2120/
```

## Limitations

- `total_indexing_lag_ms` is persisted through existing outbox timestamps.
- Per-step breakdown is emitted as runtime log output, not persisted in new database columns.
- The SQL query cannot derive `sourceDocumentLoadMs`, `openSearchWriteMs`, or `outboxStateTransitionMs` from existing outbox columns.
- The local runner is an experiment script, not the Spring scheduler.
- The JUnit instrumentation smoke does not measure real PostgreSQL or OpenSearch network time.
- No Bulk Indexing, tuning, k6 benchmark, or production readiness claim is included.

## Recommended Next Step

Use `single-index-baseline-local-20260510-2035` as the pre-Bulk single-document baseline, then compare a future Bulk path against the same local PostgreSQL + OpenSearch measurement shape.
