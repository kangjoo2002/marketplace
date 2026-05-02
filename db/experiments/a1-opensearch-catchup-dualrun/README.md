# A-1 OpenSearch Catch-up Dual-run

## Purpose

This experiment validates catch-up replay after a backfill high-watermark and compares PostgreSQL results with OpenSearch shadow results for representative exact-filter queries.

It comes after:

- OpenSearch mapping and alias smoke validation
- `search_outbox` transactional capture
- outbox relay and idempotent OpenSearch sync
- checkpoint-based OpenSearch backfill

PostgreSQL remains the source of truth. OpenSearch is only a search read model.

## Scope

This task includes:

- local catch-up replay smoke script
- isolated OpenSearch catch-up index and aliases
- selected nested mapping reuse
- fresh `backfill_start_outbox_id` recording before catch-up events
- replay of namespaced `search_outbox.id > backfill_start_outbox_id` events
- static DB/Search shadow comparison
- representative exact-filter query comparison
- mismatch, sample diff, and stale `updated_at` metrics

This task excludes:

- API read-path switch
- feature flag switch
- DB fallback path
- k6 or benchmark runs
- lag/fallback/rollback operations validation
- Kafka, Debezium, or CDC
- production monitoring or dashboarding
- relevance, synonym, typo, or autocomplete work

This is local smoke validation only, not production migration readiness.

## Source Tables And Filter

Source tables:

```text
products
product_options_moderate_skew
search_outbox
```

The local smoke uses a controlled product slice:

```text
products.id BETWEEN -20002999 AND -20002000
```

Static comparison filters searchable rows with:

```text
products.status = 'ACTIVE'
```

The product document uses the previously selected mapping contract:

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

`options` is always built as a nested array.

## Target Index And Aliases

Smoke index:

```text
products_search_catchup_smoke_v1
```

Smoke aliases:

```text
products_search_catchup_smoke_read
products_search_catchup_smoke_write
products_search_catchup_smoke_current
```

Catch-up replay writes through:

```text
products_search_catchup_smoke_write
```

Static comparison reads through:

```text
products_search_catchup_smoke_read
```

The index is created from:

```text
db/experiments/a1-opensearch-index-mapping-alias/mappings/products_v1_nested.json
```

## High-watermark And Replay Strategy

The script creates a controlled baseline state, bulk-indexes that baseline to OpenSearch, then records:

```text
backfill_start_outbox_id = max(search_outbox.id)
```

Catch-up events are inserted after that high-watermark and replayed with:

```text
search_outbox.id > backfill_start_outbox_id
payload->>'smokeRun' = 'opensearch-catchup-dualrun'
```

The smoke handles:

- `PRODUCT_CREATED`: upsert product document
- `PRODUCT_UPDATED`: upsert product document
- `PRODUCT_STATUS_CHANGED`: delete the document when the source status is `DELETED`

Successful replay events are marked `DONE`. Failed replay events are marked `FAILED` with retry metadata by the same relay lifecycle used in the relay smoke.

## Static Snapshot Comparison

After replay completes, the script captures `snapshot_captured_at` and compares DB top-k product IDs against OpenSearch top-k product IDs.

Scenarios:

- `C1_selective_option_filter`: ACTIVE category/brand filter plus nested `BLACK/S/IN_STOCK` option filter.
- `C2_active_status_filter`: broad ACTIVE filter with deterministic `review_count DESC, id DESC` ordering.
- `C3_deleted_exclusion`: option filter that only matches the status-changed deleted product; ACTIVE filter should return no results.

The default top-k is:

```text
CATCHUP_TOP_K = 50
```

Mismatch threshold:

```text
top-k mismatch ratio = 0
```

The smoke records missing IDs, extra IDs, ordering mismatches, sample diffs, and stale `sourceUpdatedAt` mismatches.

This is a shadow comparison only. It does not use OpenSearch as the API response source.

## Validation

Start PostgreSQL:

```powershell
docker compose up -d postgres
```

Start local OpenSearch smoke service:

```powershell
docker compose -f db\experiments\a1-opensearch-index-mapping-alias\docker-compose.opensearch-smoke.yml up -d
```

Run catch-up dual-run smoke:

```powershell
$env:OPENSEARCH_URL = "http://localhost:9200"
.\db\experiments\a1-opensearch-catchup-dualrun\scripts\run-opensearch-catchup-dualrun.ps1
```

Optional OpenSearch smoke teardown:

```powershell
docker compose -f db\experiments\a1-opensearch-index-mapping-alias\docker-compose.opensearch-smoke.yml down -v
```

## Expected Result

| metric | expected |
|---|---:|
| replayed event count | 3 |
| pending after replay | 0 |
| failed after replay | 0 |
| compared query count | 3 |
| mismatch count | 0 |
| mismatch ratio | 0 |
| top-k mismatch count | 0 |
| missing in search count | 0 |
| extra in search count | 0 |
| ordering mismatch count | 0 |
| sample diff count | 0 |
| stale by updated_at count | 0 |

## Generated Artifacts

Successful runs write:

```text
results/<timestamp>/catchup-dualrun-summary.md
results/<timestamp>/high-watermark-result.json
results/<timestamp>/replay-summary-result.json
results/<timestamp>/static-snapshot-result.json
results/<timestamp>/db-query-results.json
results/<timestamp>/search-query-results.json
results/<timestamp>/mismatch-report.json
results/<timestamp>/sample-diff-result.json
results/<timestamp>/stale-updated-at-result.json
```

If validation fails, the script removes the temporary result directory and does not create pass artifacts.

## Limitations

- Experiment-level script only; application worker integration is not changed.
- Source data is a controlled local smoke slice.
- Representative scenarios are controlled smoke queries, not the official B1/B2/B3 API benchmark.
- No API read-path switch.
- No feature flag or DB fallback.
- No k6 benchmark.
- No production readiness claim.

## Next Step

Validate lag, fallback, and rollback operations before any API read-path switch.
