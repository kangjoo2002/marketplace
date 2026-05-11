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
