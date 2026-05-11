# A-1 Search Outbox Indexing Latency Observations

## Current Status

Primary scaling smoke:

```text
results/spring-replica-scaling-smoke-local-20260511-1340/
```

Single-batch reference results only:

```text
results/worker-count-attribution-local-20260510-2157/
results/spring-replica-relay-smoke-steady-state-local-20260511-1200/
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

| replicaCount | totalProcessingTimeMs | totalIndexingLagMs p50 | totalIndexingLagMs p95 | totalIndexingLagMs p99 | totalIndexingLagMs max | queueWaitMs p50 | queueWaitMs p95 | queueWaitMs p99 | queueWaitMs max | sourceDocumentLoadMs p50/p95/p99/max | openSearchWriteMs p50/p95/p99/max | outboxStateTransitionMs p50/p95/p99/max | relayProcessingMs p50/p95/p99/max | DONE | FAILED | PENDING | PROCESSING | duplicate claim | retry/failed | batch claim count | first claim at | last DONE at |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|---|---|---|---:|---:|---:|---:|---|---|---:|---|---|
| 1 | 65675 | 34162.3465 | 64264.523949999995 | 64879.75836 | 65045.6660000 | 30044 | 63424 | 63424 | 63424 | 4 / 8 / 15 / 491 | 6 / 11 / 18 / 120 | 5 / 9 / 16 / 120 | 16 / 28 / 50 / 720 | 1000 | 0 | 0 | 0 | false | false | 10 | 2026-05-11T04:57:40.5660000+00:00 | 2026-05-11T04:58:44.9830000+00:00 |
| 2 | 42472 | 23443.8675 | 41178.14565 | 41805.12879 | 41955.8840000 | 18137 | 40235 | 40235 | 40235 | 6 / 21 / 46 / 2576 | 7 / 22 / 49 / 128 | 6 / 22 / 43 / 233 | 21 / 66 / 137 / 2933 | 1000 | 0 | 0 | 0 | false | false | 10 | 2026-05-11T04:59:18.9840000+00:00 | 2026-05-11T05:00:00.3660000+00:00 |
| 4 | 33011 | 18605.6665 | 31947.1076 | 32666.992179999997 | 32823.2040000 | 15624 | 31076 | 31076 | 31076 | 14 / 43 / 90 / 2650 | 15 / 50 / 159 / 415 | 14 / 50 / 101 / 483 | 46 / 141 / 250 / 3201 | 1000 | 0 | 0 | 0 | false | false | 10 | 2026-05-11T05:01:09.0250000+00:00 | 2026-05-11T05:01:40.7260000+00:00 |

Replica claim counts:

| replicaCount | replica | claimCount | timingLogLineCount | batchClaimCount | firstClaimAt | lastDoneAt |
|---:|---|---:|---:|---:|---|---|
| 1 | spring-app-1 | 1000 | 1000 | 10 | 2026-05-11T04:57:40.5660000+00:00 | 2026-05-11T04:58:44.9830000+00:00 |
| 2 | spring-app-1 | 500 | 500 | 5 | 2026-05-11T04:59:18.9840000+00:00 | 2026-05-11T04:59:54.4070000+00:00 |
| 2 | spring-app-2 | 500 | 500 | 5 | 2026-05-11T04:59:23.4280000+00:00 | 2026-05-11T05:00:00.3660000+00:00 |
| 4 | spring-app-1 | 200 | 200 | 2 | 2026-05-11T05:01:12.6030000+00:00 | 2026-05-11T05:01:34.1200000+00:00 |
| 4 | spring-app-2 | 300 | 300 | 3 | 2026-05-11T05:01:12.2510000+00:00 | 2026-05-11T05:01:40.7260000+00:00 |
| 4 | spring-app-3 | 200 | 200 | 2 | 2026-05-11T05:01:11.6940000+00:00 | 2026-05-11T05:01:34.1760000+00:00 |
| 4 | spring-app-4 | 300 | 300 | 3 | 2026-05-11T05:01:09.0250000+00:00 | 2026-05-11T05:01:36.0280000+00:00 |

Raw results:

```text
db/experiments/a1-search-outbox-indexing-latency/results/spring-replica-scaling-smoke-local-20260511-1340/
```
