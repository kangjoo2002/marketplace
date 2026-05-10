# Single-Document Indexing Baseline Procedure

## Purpose

This procedure records the local synthetic baseline for the current single-document indexing path:

```text
one claimed search_outbox event -> one OpenSearch document write
```

It uses local PostgreSQL and local OpenSearch. It does not start the Spring Boot app or scheduler.

This is measurement-only. It does not tune batch size, scheduler delay, retry policy, claim behavior, OpenSearch mapping, or indexing architecture.

## Environment Label

All results from this procedure must be labeled:

```text
local synthetic / local PostgreSQL + OpenSearch smoke
```

Do not interpret them as production SLO/SLA, production capacity, or steady-state throughput.

## Baseline Scale

The committed baseline run processes:

```text
eventCount = 100
```

## Measurement Flow

The script:

1. Creates isolated source rows in local PostgreSQL.
2. Inserts namespaced `search_outbox` rows with `payload.smokeRun = <runId>`.
3. Claims rows with `FOR UPDATE SKIP LOCKED`.
4. Loads the current product/options document from PostgreSQL.
5. Writes one document to OpenSearch per claimed event.
6. Marks the outbox row `DONE`.
7. Runs `measure-indexing-lag.sql` for the same `smokeRun`.
8. Writes summary and timing sample artifacts.

Measured fields:

- event count processed
- total processing time
- DONE / FAILED / pending / processing counts
- `totalIndexingLagMs`
- `queueWaitMs`
- `sourceDocumentLoadMs`
- `openSearchWriteMs`
- `outboxStateTransitionMs`
- `relayProcessingMs`
- OpenSearch write/delete call count

## Local PostgreSQL Setup

Start a disposable PostgreSQL container with the same database/user/password that the baseline script uses by default:

```powershell
docker run -d `
  --name readpath-baseline-postgres `
  -e POSTGRES_DB=marketplace `
  -e POSTGRES_USER=marketplace `
  -e POSTGRES_PASSWORD=marketplace `
  -p 15432:5432 `
  postgres:16
```

The baseline script connects inside the container with:

```text
psql -U marketplace -d marketplace
```

It initializes the minimal local schema needed for this smoke run before inserting measurement rows:

- `products`
- `product_options`
- `search_outbox`
- `pgcrypto` extension for `gen_random_uuid()`
- supporting indexes used by the local claim/query path

The committed run used `readpath-baseline-postgres` on host port `15432` because local port `5432` was already occupied by another project container.

## Command

Start local OpenSearch using the repository smoke compose file, then run:

```powershell
docker compose -f db\experiments\a1-opensearch-index-mapping-alias\docker-compose.opensearch-smoke.yml up -d

db\experiments\a1-search-outbox-indexing-latency\scripts\run-single-index-baseline.ps1 `
  -RunId single-index-baseline-local-YYYYMMDD-HHMM `
  -EventCount 100 `
  -PostgresContainer readpath-baseline-postgres `
  -PostgresUser marketplace `
  -PostgresDatabase marketplace `
  -OpenSearchUrl http://localhost:9200
```

## Artifact Shape

Successful measured runs create:

```text
db/experiments/a1-search-outbox-indexing-latency/results/<run-id>/
  summary.md
  indexing-lag-summary.json
  relay-log-sample.txt
```

## Relay Instrumentation Smoke

The JUnit artifact under `results/relay-instrumentation-smoke-junit-20260510/` is not the Bulk comparison baseline.

It validates the relay timing log shape with a `CountingIndexWriter`. Do not use those values as the single-index OpenSearch baseline.

## Non-Goals

- No Bulk Indexing
- No batch size tuning
- No retry/backoff change
- No circuit breaker change
- No OpenSearch mapping change
- No fallback behavior change
- No claim behavior change
- No scheduler delay change
- No k6 benchmark
- No production SLO/SLA claim
- No invented numbers
