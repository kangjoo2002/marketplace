# A-1 Search Outbox Indexing Latency Observations

## Current Status

This experiment currently uses the Spring replica relay smoke as the primary local synthetic reference.

Primary result:

```text
results/spring-replica-relay-smoke-local-20260511-1035/
```

Script-based workerCount attribution remains only as WIP/reference material. It is not the primary conclusion because it is a script relay shape, not the Spring scheduler replica shape.

Reference result:

```text
results/worker-count-attribution-local-20260510-2157/
```

The JUnit artifact is relay instrumentation smoke only:

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
- Local smoke runners:
  - `scripts/run-single-index-baseline.ps1`
  - `scripts/run-queue-wait-attribution.ps1`
  - `scripts/run-worker-count-attribution.ps1`
  - `scripts/run-spring-replica-relay-smoke.ps1`

## Measurement Method

The Spring replica relay smoke is a local synthetic PostgreSQL + OpenSearch smoke:

- disposable PostgreSQL is started with `POSTGRES_DB=marketplace`, `POSTGRES_USER=marketplace`, and `POSTGRES_PASSWORD=marketplace`
- the runner initializes the minimal `products`, `product_options`, and `search_outbox` schema before loading smoke data
- source rows are inserted into local PostgreSQL
- `search_outbox` rows are inserted with a `smokeRun` marker
- Spring app replicas run the scheduler relay against the same PostgreSQL and OpenSearch services
- rows are claimed by the relay with the existing claim path
- each claimed event performs one OpenSearch document write
- outbox rows are marked `DONE`
- `measure-indexing-lag.sql` records total lag and queue/status counts
- relay logs provide the per-step timing breakdown

The JUnit artifact validates relay timing instrumentation only. CountingIndexWriter-based values must not be used as the single-index OpenSearch baseline.

## 2026-05-11 Spring Replica Relay Smoke

Experiment conditions:

- Environment: local synthetic / local PostgreSQL + OpenSearch smoke
- eventCount: 100
- batchSize: 100
- scheduler relay enabled
- Cases: Spring app replica 1, 2, and 4

| replicaCount | totalProcessingTimeMs | totalIndexingLagMs p50 | totalIndexingLagMs p95 | totalIndexingLagMs p99 | totalIndexingLagMs max | queueWaitMs p50 | queueWaitMs p95 | queueWaitMs p99 | queueWaitMs max | sourceDocumentLoadMs p50/p95/p99/max | openSearchWriteMs p50/p95/p99/max | outboxStateTransitionMs p50/p95/p99/max | relayProcessingMs p50/p95/p99/max | DONE | FAILED | PENDING | PROCESSING | relay timing log lines | duplicate claim | retry/failed |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|---|---|---|---:|---:|---:|---:|---:|---|---|
| 1 | 54482 | 52345.01149999999 | 54051.736750000004 | 54121.305 | 54138.5310000 | 49475 | 49475 | 49475 | 49475 | 7 / 26 / 49 / 539 | 9 / 33 / 243 / 438 | 7 / 24 / 64 / 140 | 25 / 80 / 357 / 1118 | 100 | 0 | 0 | 0 | 100 | false | false |
| 2 | 33825 | 32229.271 | 33276.818199999994 | 33367.90377 | 33386.4930000 | 29882 | 29882 | 29882 | 29882 | 6 / 11 / 11 / 858 | 7 / 12 / 15 / 305 | 6 / 8 / 13 / 135 | 20 / 30 / 34 / 1300 | 100 | 0 | 0 | 0 | 100 | false | false |
| 4 | 43518 | 42285.0965 | 43221.5666 | 43292.49115 | 43308.6430000 | 39441 | 39441 | 39441 | 39441 | 6 / 12 / 14 / 896 | 8 / 14 / 28 / 426 | 6 / 12 / 14 / 161 | 20 / 33 / 56 / 1484 | 100 | 0 | 0 | 0 | 100 | false | false |

Raw measurement results:

```text
db/experiments/a1-search-outbox-indexing-latency/results/spring-replica-relay-smoke-local-20260511-1035/
```

Summary:

- replica 1 to 2 improved in this local synthetic smoke.
- replica 2 to 4 regressed in this local synthetic smoke.
- DONE 100, FAILED 0, and duplicate claim false were observed for every replica case.
- Replica increase was not linear scaling in this local synthetic smoke.

## 2026-05-10 Worker Count Attribution Script-Based Reference

This result is WIP/reference only. It uses a script-based relay shape and is not the primary Spring replica conclusion.

Experiment conditions:

- Environment: local synthetic / local PostgreSQL + OpenSearch smoke
- eventCount: 100
- batchSize: 100
- Cases: workerCount 1, 2, and 4

| workerCount | totalProcessingTimeMs | totalIndexingLagMs p50 | totalIndexingLagMs p95 | totalIndexingLagMs p99 | totalIndexingLagMs max | queueWaitMs p50 | queueWaitMs p95 | queueWaitMs p99 | queueWaitMs max | sourceDocumentLoadMs p50/p95/p99/max | openSearchWriteMs p50/p95/p99/max | outboxStateTransitionMs p50/p95/p99/max | relayProcessingMs p50/p95/p99/max | OpenSearch write/delete calls | relay timing log lines |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|---|---|---|---:|---:|
| 1 | 29098 | 16159.261999999999 | 28311.890499999998 | 29389.908010000003 | 29640.1810000 | 355 | 355 | 355 | 355 | 128 / 189 / 211 / 244 | 8 / 20 / 75 / 101 | 128 / 161 / 199 / 199 | 267 / 335 / 389 / 468 | 100 | 100 |
| 2 | 18012 | 10518.949499999999 | 17576.1267 | 18167.81555 | 18321.3200000 | 213 | 213 | 213 | 213 | 150 / 219 / 291 / 312 | 7 / 12 / 149 / 160 | 150 / 214 / 283 / 297 | 306 / 456 / 683 / 724 | 100 | 100 |
| 4 | 20283 | 13045.551500000001 | 19798.66315 | 20464.803050000002 | 20517.5750000 | 184 | 184 | 184 | 184 | 212 / 589 / 702 / 819 | 9 / 71 / 266 / 270 | 214 / 525 / 564 / 609 | 458 / 1080 / 1273 / 1436 | 100 | 100 |

Raw measurement results:

```text
db/experiments/a1-search-outbox-indexing-latency/results/worker-count-attribution-local-20260510-2157/
```

## 2026-05-10 Queue Wait Attribution

Experiment conditions:

- Environment: local synthetic / local PostgreSQL + OpenSearch smoke
- eventCount: 100
- workerCount: 1
- Cases: batchSize 20 and batchSize 100

| batchSize | totalProcessingTimeMs | totalIndexingLagMs p50 | totalIndexingLagMs p95 | totalIndexingLagMs p99 | totalIndexingLagMs max | queueWaitMs p50 | queueWaitMs p95 | queueWaitMs p99 | queueWaitMs max | sourceDocumentLoadMs p50/p95/p99/max | openSearchWriteMs p50/p95/p99/max | outboxStateTransitionMs p50/p95/p99/max | relayProcessingMs p50/p95/p99/max | OpenSearch write/delete calls | relay timing log lines |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|---|---|---|---:|---:|
| 20 | 82422 | 45802.308000000005 | 79457.4898 | 81886.11067000001 | 82576.4050000 | 36295 | 70085 | 70085 | 70085 | 317 / 634 / 1233 / 1574 | 62 / 120 / 198 / 250 | 327 / 626 / 798 / 1571 | 720 / 1267 / 1976 / 2567 | 100 | 100 |
| 100 | 56695 | 29800.853000000003 | 54099.1885 | 56219.62305 | 56711.2620000 | 219 | 219 | 219 | 219 | 251 / 384 / 463 / 593 | 59 / 77 / 96 / 112 | 230 / 356 / 439 / 696 | 547 / 775 / 900 / 1065 | 100 | 100 |

Raw measurement results:

```text
db/experiments/a1-search-outbox-indexing-latency/results/queue-wait-attribution-local-20260510-2120/
```

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

## Limitations

- `total_indexing_lag_ms` is persisted through existing outbox timestamps.
- Per-step breakdown is emitted as runtime log output, not persisted in new database columns.
- The SQL query cannot derive `sourceDocumentLoadMs`, `openSearchWriteMs`, or `outboxStateTransitionMs` from existing outbox columns.
- Script-based workerCount attribution is WIP/reference only and is not the Spring scheduler replica shape.
- The JUnit instrumentation smoke does not measure real PostgreSQL or OpenSearch network time.
- No Bulk Indexing, tuning, k6 benchmark, production readiness, SLO, or SLA claim is included.

## Current Analysis Direction

Use the Spring replica relay smoke as the primary local synthetic result. The next analysis target is scheduler/claim timing, claim distribution by replica, and shared resource contention.
