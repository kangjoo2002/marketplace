# A-1 OpenSearch Backfill Checkpoint

## Purpose

This experiment validates checkpoint-based PostgreSQL to OpenSearch backfill with the selected product search document contract.

It comes after:

- OpenSearch mapping and alias smoke validation
- `search_outbox` transactional capture
- outbox relay and idempotent OpenSearch sync

PostgreSQL remains the source of truth. OpenSearch is a search read model.

## Scope

This task includes:

- local backfill smoke script
- isolated OpenSearch backfill index and aliases
- selected nested mapping reuse
- `backfill_start_outbox_id` high-watermark recording
- checkpoint file with resume cursor
- controlled interruption and resume validation
- batch-based bulk indexing
- source/index count validation
- missing/extra document validation
- sample document comparison
- local duration and throughput metrics

This task excludes:

- catch-up replay after backfill
- DB/Search dual-run comparison
- API read-path switch
- feature flag switch
- DB fallback path
- k6 or benchmark runs
- Kafka, Debezium, or CDC
- production monitoring or dashboarding
- relevance, synonym, typo, or autocomplete work

This is local backfill validation only, not production migration readiness.

## Source Tables And Filter

Source tables:

```text
products
product_options_moderate_skew
search_outbox
```

The local smoke uses a controlled source slice:

```text
products.id BETWEEN -19002999 AND -19002000
```

This keeps validation deterministic and avoids production-like load tests. Count validation uses the same source filter.

The product document uses:

- `productId`
- `sellerId`
- `categoryId`
- `brandId`
- `status`
- `price`
- `rating`
- `reviewCount`
- `createdAt`
- `updatedAt`
- `sourceUpdatedAt`
- `documentRefreshedAt`
- `options[].color`
- `options[].size`
- `options[].stockStatus`

`options` is always an array and uses the selected nested mapping.

## Target Index And Aliases

Smoke index:

```text
products_search_backfill_smoke_v1
```

Smoke aliases:

```text
products_search_backfill_smoke_read
products_search_backfill_smoke_write
products_search_backfill_smoke_current
```

The backfill writes through:

```text
products_search_backfill_smoke_write
```

The index is created from:

```text
db/experiments/a1-opensearch-index-mapping-alias/mappings/products_v1_nested.json
```

## High-watermark Strategy

Before the backfill starts, the script records:

```text
backfill_start_outbox_id = max(search_outbox.id)
```

If no rows exist, the recorded value is `0`.

Future catch-up replay should start from:

```text
search_outbox.id > backfill_start_outbox_id
```

Catch-up replay is not implemented in this task.

## Checkpoint Strategy

The smoke uses a checkpoint file written under a temporary result directory while the script is running. On success, the directory is renamed to the final timestamped artifact directory.

Checkpoint fields:

- `backfillRunId`
- `lastProcessedProductId`
- `batchSize`
- `status`
- `startedAt`
- `updatedAt`
- `completedAt`

Cursor:

```text
product_id ascending
```

The script intentionally stops after the first batch, verifies the saved cursor, resumes from that cursor, and completes the remaining rows.

## Batch Strategy

The script uses OpenSearch `_bulk` with a configurable batch size.

Default local smoke batch size:

```text
BACKFILL_BATCH_SIZE = 2
```

Failed batch count and retried batch count are recorded. The smoke does not tune performance and does not claim production throughput.

## Validation

Start PostgreSQL:

```powershell
docker compose up -d postgres
```

Start local OpenSearch smoke service:

```powershell
docker compose -f db\experiments\a1-opensearch-index-mapping-alias\docker-compose.opensearch-smoke.yml up -d
```

Run backfill smoke:

```powershell
$env:OPENSEARCH_URL = "http://localhost:9200"
.\db\experiments\a1-opensearch-backfill-checkpoint\scripts\run-opensearch-backfill-checkpoint.ps1
```

Optional OpenSearch smoke teardown:

```powershell
docker compose -f db\experiments\a1-opensearch-index-mapping-alias\docker-compose.opensearch-smoke.yml down -v
```

## Expected Result

| metric | expected |
|---|---:|
| source product count | 4 |
| indexed document count | 4 |
| missing document count | 0 |
| extra document count | 0 |
| sample document mismatch count | 0 |
| failed batch count | 0 |
| retried batch count | 0 |
| resume success | true |

## Generated Artifacts

Successful runs write:

```text
results/<timestamp>/backfill-summary.md
results/<timestamp>/high-watermark-result.json
results/<timestamp>/checkpoint-result.json
results/<timestamp>/resume-result.json
results/<timestamp>/count-validation-result.json
results/<timestamp>/missing-extra-validation-result.json
results/<timestamp>/sample-document-comparison-result.json
results/<timestamp>/batch-stats-result.json
```

If validation fails, the script removes the temporary result directory and does not create pass artifacts.

## Limitations

- Experiment-level script only; application batch integration remains future work.
- Source data is a controlled local smoke slice.
- No catch-up replay.
- No DB/Search dual-run.
- No API read-path switch.
- No k6 benchmark.
- Duration and throughput are local smoke metrics only.

## Next Step

Implement catch-up replay plus DB/Search dual-run verification.
