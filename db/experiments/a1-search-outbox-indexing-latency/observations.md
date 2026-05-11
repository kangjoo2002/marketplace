# A-1 Search Outbox Indexing Latency Observations

## Current Status

Primary scaling smoke:

```text
results/spring-replica-scaling-smoke-local-20260511-1622/
```

The script-based workerCount result and the Spring replica `eventCount=100`, `batchSize=100` result are not scaling evidence because one worker/replica can claim all rows in a single batch.

## 2026-05-11 — Spring replica steady-state scaling smoke

Experiment conditions:

- Environment: local PostgreSQL + local OpenSearch
- Spring app replicas: 1, 2, 4
- eventCount: 1000
- batchSize: 100
- scheduler relay enabled
- Spring app replicas started before smoke row insert
- all replicas returned actuator health `UP`
- stabilizationSeconds: 3
- each case executed once

| replicaCount | totalProcessingTimeMs | totalIndexingLagMs p50 | totalIndexingLagMs p95 | totalIndexingLagMs p99 | totalIndexingLagMs max | queueWaitMs p50 | queueWaitMs p95 | queueWaitMs p99 | queueWaitMs max | DONE | FAILED | PENDING | PROCESSING | duplicate claim | retry/failed | batch claim count | first claim at | last DONE at |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|---|---:|---|---|
| 1 | 59060 | 30928.074 | 58231.97895 | 58638.50535 | 58742.65 | 30405.167500000003 | 57720.433 | 57720.433 | 57720.433 | 1000 | 0 | 0 | 0 | false | false | 10 | 2026-05-11T07:22:41.669433+00:00 | 2026-05-11T07:23:38.967651+00:00 |
| 2 | 27450 | 14038.35 | 26572.9839 | 26878.55102 | 26964.566 | 13314.2065 | 25963.724 | 25963.724 | 25963.724 | 1000 | 0 | 0 | 0 | false | false | 10 | 2026-05-11T07:23:55.803089+00:00 | 2026-05-11T07:24:22.548791+00:00 |
| 4 | 16160 | 8969.813999999998 | 15510.03335 | 15717.91418 | 15805.851 | 8321.688 | 14684.716 | 14684.716 | 14684.716 | 1000 | 0 | 0 | 0 | false | false | 10 | 2026-05-11T07:24:54.274555+00:00 | 2026-05-11T07:25:09.132252+00:00 |

Replica claim counts:

| replicaCount | replica | claimCount | claimedRowCount | batchClaimCount | firstClaimAt | lastDoneAt |
|---:|---|---:|---:|---:|---|---|
| 1 | spring-app-1 | 1000 | 1000 | 10 | 2026-05-11T07:22:41.669433+00:00 | 2026-05-11T07:23:38.967651+00:00 |
| 2 | spring-app-1 | 500 | 500 | 5 | 2026-05-11T07:23:55.803089+00:00 | 2026-05-11T07:24:22.20664+00:00 |
| 2 | spring-app-2 | 500 | 500 | 5 | 2026-05-11T07:23:56.304775+00:00 | 2026-05-11T07:24:22.548791+00:00 |
| 4 | spring-app-1 | 300 | 300 | 3 | 2026-05-11T07:24:54.500676+00:00 | 2026-05-11T07:25:09.132252+00:00 |
| 4 | spring-app-2 | 200 | 200 | 2 | 2026-05-11T07:24:55.228126+00:00 | 2026-05-11T07:25:03.609295+00:00 |
| 4 | spring-app-3 | 200 | 200 | 2 | 2026-05-11T07:24:56.933494+00:00 | 2026-05-11T07:25:04.725452+00:00 |
| 4 | spring-app-4 | 300 | 300 | 3 | 2026-05-11T07:24:54.274555+00:00 | 2026-05-11T07:25:09.008039+00:00 |

Raw results:

```text
db/experiments/a1-search-outbox-indexing-latency/results/spring-replica-scaling-smoke-local-20260511-1622/
```

## 2026-05-11 — Backlog polling delay attribution

Experiment conditions:

- Environment: local PostgreSQL + local OpenSearch
- eventCount: 1000
- batchSize: 100
- replicaCount: 1
- Spring app started before smoke row insert
- Spring app returned actuator health `UP`
- stabilizationSeconds: 3
- each case executed once

| fixedDelayMs | totalProcessingTimeMs | DONE | FAILED | PENDING | PROCESSING | totalIndexingLagMs p95 | queueWaitMs p95 | batchClaimCount | row count by claimed_by | duplicate claim | retry/failed |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|---|---|
| 5000 | 58458 | 1000 | 0 | 0 | 0 | 57340.06509999999 | 56820.936 | 10 | spring-app-1=1000 | false | false |
| 1000 | 22467 | 1000 | 0 | 0 | 0 | 21349.2774 | 20663.721 | 10 | spring-app-1=1000 | false | false |
| 100 | 12663 | 1000 | 0 | 0 | 0 | 11681.40435 | 11257.34 | 10 | spring-app-1=1000 | false | false |

Result path:

```text
db/experiments/a1-search-outbox-indexing-latency/results/backlog-polling-delay-attribution-20260511-1652/result.txt
```

## 2026-05-11 — Prometheus-based distributed backlog strategy comparison

Experiment conditions:

- Environment: local PostgreSQL + local OpenSearch
- Prometheus server with `scrape_interval=1s`, `evaluation_interval=1s`
- eventCount: 4000
- replicaCount: 4
- Spring app health `UP` before insert
- Prometheus targets `UP` and scraped at least twice before insert
- Prometheus `processedRowsTotal` waited until it matched DB `DONE`
- idleSeconds: 30
- each case executed once

| order | case | batchSize | fixedDelayMs | maxDrainRounds | totalProcessingTimeMs | eventsPerSecond | schedulerRunCount | emptyRunCount | nonEmptyRunCount | batchAttemptCount | processedRowsTotal | schedulerRunDuration p95 | claimRows p50 | claimRows p95 | claimRows max | queueWaitMs p50 | queueWaitMs p95 | queueWaitMs p99 | queueWaitMs max | totalIndexingLagMs p50 | totalIndexingLagMs p95 | totalIndexingLagMs p99 | totalIndexingLagMs max | batchClaimCount | avgRowsPerClaim | maxRowsPerClaim | DONE | FAILED | PENDING | PROCESSING | retryCount | duplicateClaim | DB DONE = Prom processedRowsTotal |
|---:|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|---|
| 1 | baseline | 100 | 5000 | 1 | 72858 | 54.9 | 42.0 | 2.0 | 40.0 | 42.0 | 4000.0 | 4.831576 | 100.0 | 100.0 | 100.0 | 35777.3295 | 68586.30374999976 | 70495.235 | 70495.235 | 36668.085 | 69754.4047 | 71402.25275 | 72236.568 | 40 | 100.0 | 100 | 4000 | 0 | 0 | 0 | 0 | false | true |
| 2 | shorter polling | 100 | 1000 | 1 | 45152 | 88.59 | 59.0 | 19.0 | 40.0 | 59.0 | 4000.0 | 7.247495 | 100.0 | 100.0 | 100.0 | 25406.9465 | 42968.96734999999 | 43005.195 | 43005.195 | 26863.2325 | 43607.8028 | 44560.69733 | 44793.175 | 40 | 100.0 | 100 | 4000 | 0 | 0 | 0 | 0 | false | true |
| 3 | larger batch | 500 | 5000 | 1 | 44697 | 89.49 | 11.0 | 3.0 | 8.0 | 11.0 | 4000.0 | 20.400833 | 496.0 | 496.0 | 500.0 | 14634.904999999999 | 28306.799 | 28306.799 | 28306.799 | 24001.949500000002 | 42028.38735 | 43633.62555 | 44178.312 | 8 | 500.0 | 500 | 4000 | 0 | 0 | 0 | 0 | false | true |
| 4 | multi-batch per scheduler run | 100 | 5000 | 5 | 40377 | 99.07 | 12.0 | 3.0 | 9.0 | 45.0 | 4000.0 | 19.327091 | 100.0 | 100.0 | 100.0 | 21119.1855 | 36296.321599999595 | 37947.504 | 37947.504 | 22616.882 | 38273.38575 | 39806.91362 | 40237.579 | 40 | 100.0 | 100 | 4000 | 0 | 0 | 0 | 0 | false | true |

Replica claim distribution:

| case | spring-app-1 | spring-app-2 | spring-app-3 | spring-app-4 |
|---|---:|---:|---:|---:|
| baseline | 1000 | 1000 | 1000 | 1000 |
| shorter polling | 1000 | 1000 | 1000 | 1000 |
| larger batch | 1000 | 1000 | 1000 | 1000 |
| multi-batch per scheduler run | 900 | 1000 | 1100 | 1000 |

Idle polling:

| case | schedulerRunCount | emptyRunCount | nonEmptyRunCount | emptyRunRatio | batchAttemptCount | emptyBatchAttemptCount | nonEmptyBatchAttemptCount | processedRowsTotal |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| baseline | 24.0 | 24.0 | 0.0 | 1.0 | 24.0 | 24.0 | 0.0 | 0.0 |
| shorter polling | 119.0 | 119.0 | 0.0 | 1.0 | 119.0 | 119.0 | 0.0 | 0.0 |
| larger batch | 24.0 | 24.0 | 0.0 | 1.0 | 24.0 | 24.0 | 0.0 | 0.0 |
| multi-batch per scheduler run | 24.0 | 24.0 | 0.0 | 1.0 | 24.0 | 24.0 | 0.0 | 0.0 |

Trade-off notes:

- Shorter polling: implementation is simple, idle polling may increase.
- Larger batch: claim count decreases, larger batches may concentrate ownership on some replicas.
- Multi-batch per scheduler run: consecutive processing happens only while backlog exists, implementation complexity increases.

Result path:

```text
db/experiments/a1-search-outbox-indexing-latency/results/prometheus-distributed-backlog-strategy-comparison-20260511-2111/result.txt
```

Decision note:

The main remaining latency was `queueWait`, and fixedDelay attribution showed batch-to-batch polling delay was a major contributor. The distributed Prometheus comparison evaluated shorter polling, larger batch, and multi-batch per scheduler run: shorter polling reduced latency but increased idle polling, larger batch reduced `queueWait` but increases per-claim batch size, and multi-batch per scheduler run kept `fixedDelayMs` and `batchSize` unchanged, did not increase idle polling, and produced the best `totalProcessingTimeMs` / `totalIndexingLagMs p95` in the corrected run. Therefore A-1 selected `maxDrainRounds=5` before moving to larger changes like Bulk Indexing or payload snapshot.

## ProductId duplicate reindex reduction

Problem: the same `productId` can appear multiple times in one relay batch. Before, the same `productId` repeated N times was processed N times. After, the same `productId` repeated N times in one already-claimed relay batch is processed once.

Scope: this applies only inside one already-claimed batch. The processing unit changes from a single outbox row to a `productId` group; if one `productId` group fails, multiple rows for that `productId` may retry together. Intermediate states are not indexed, which is valid here because the search index stores the latest product state.

Limitation: duplicates split across different batches are not merged in this PR.
