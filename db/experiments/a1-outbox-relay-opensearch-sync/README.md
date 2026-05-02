# A-1 Outbox Relay OpenSearch Sync

## Purpose

This experiment validates the relay side of the product search outbox flow with real PostgreSQL and real OpenSearch.

The previous work established:

- OpenSearch product mapping and aliases
- `options: nested`
- `search_outbox`
- transactional product write + outbox insert capture

This task consumes `PENDING` outbox events, writes product documents through a local OpenSearch write alias, and verifies idempotent replay, failure metadata, and DONE cleanup semantics.

PostgreSQL remains the source of truth. OpenSearch is a search read model.

## Scope

This task includes:

- experiment-level relay script
- `PENDING` event claiming with `FOR UPDATE SKIP LOCKED`
- `PROCESSING` to `DONE` transition on success
- `PROCESSING` to `FAILED` transition on write failure
- product document build from PostgreSQL source rows
- nested `options` document shape
- OpenSearch upsert through a write alias
- status-change delete behavior for `DELETED`
- idempotent replay validation
- local DONE cleanup retention validation
- result artifacts from real smoke execution

This task excludes:

- full backfill
- checkpoint-based migration
- catch-up replay after backfill
- DB/Search dual-run comparison
- API read-path switch
- feature flag switch
- DB fallback path
- k6 or benchmark runs
- Kafka, Debezium, or CDC
- production monitoring or dashboarding
- relevance, synonym, typo, or autocomplete work

This is local smoke validation only, not a production deployment or capacity claim.

## Relay Event Lifecycle

The relay uses the existing `search_outbox` statuses:

```text
PENDING -> PROCESSING -> DONE
PENDING -> PROCESSING -> FAILED
```

Success:

- writes or deletes the OpenSearch document
- sets `status = DONE`
- sets `processed_at = now()`
- clears `last_error`

Failure:

- sets `status = FAILED`
- increments `retry_count`
- records `last_error`
- sets `processed_at = now()`
- preserves the failed row for future diagnosis/retry

## Claiming Strategy

The smoke relay claims events in a PostgreSQL transaction:

```sql
WITH claimed AS (
    SELECT id
    FROM search_outbox
    WHERE status = 'PENDING'
    ORDER BY id
    FOR UPDATE SKIP LOCKED
    LIMIT :batchSize
)
UPDATE search_outbox
SET status = 'PROCESSING'
WHERE id IN (SELECT id FROM claimed)
RETURNING ...
```

The smoke script filters to its own namespace:

```text
payload.smokeRun = outbox-relay-opensearch-sync
```

It does not process unrelated outbox rows by default.

## OpenSearch Target

The smoke script creates an isolated index and aliases:

```text
products_search_relay_smoke_v1
products_search_relay_smoke_read
products_search_relay_smoke_write
products_search_relay_smoke_current
```

The relay writes through:

```text
products_search_relay_smoke_write
```

The index is created from:

```text
db/experiments/a1-opensearch-index-mapping-alias/mappings/products_v1_nested.json
```

The previous mapping contract is reused unchanged.

## Document Build Strategy

The relay builds a product document from PostgreSQL source rows:

- `products`
- `product_options_moderate_skew`

Smoke documents include:

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

`options` is built as a nested array. The relay does not use the unsafe object-array candidate.

## Event Handling

Handled events:

| event type | behavior |
|---|---|
| `PRODUCT_CREATED` | upsert document by product id |
| `PRODUCT_UPDATED` | upsert document by product id |
| `PRODUCT_STATUS_CHANGED` | delete document when source status is `DELETED`; otherwise upsert |

`PRODUCT_DELETED` tombstone handling is policy-only in this smoke because the repository does not currently have a hard-delete product write path. Future hard deletes must insert a tombstone outbox event before deleting the source row in the same transaction.

## Idempotency

The OpenSearch document id is the product id.

The smoke validates:

- create/update events write one final document
- replaying the same update event does not create duplicate documents
- final document mismatch count is `0`
- duplicate replay count is `0`

## Failure Behavior

The smoke inserts a namespaced event and processes it with an invalid OpenSearch URL.

Expected result:

- event status becomes `FAILED`
- `retry_count` increments
- `last_error` is non-empty
- failed event is retained

No retry scheduler is implemented in this task.

## DONE Cleanup / Retention

Local smoke retention value:

```text
SEARCH_OUTBOX_DONE_RETENTION_DAYS = 7
```

Cleanup deletes only:

```text
status = DONE and processed_at older than 7 days
```

Cleanup retains:

- recent `DONE`
- `FAILED`
- `PENDING`

The smoke also reports `oldestPendingAgeSeconds`. In this experiment that value is measured from namespaced smoke retention data, including an intentionally retained old `PENDING` row. It is not an operational relay lag metric.

This validates cleanup semantics only. It is not a production retention policy.

## Validation Commands

Start PostgreSQL:

```powershell
docker compose up -d postgres
```

Start local OpenSearch smoke service:

```powershell
docker compose -f db\experiments\a1-opensearch-index-mapping-alias\docker-compose.opensearch-smoke.yml up -d
```

Run relay smoke:

```powershell
$env:OPENSEARCH_URL = "http://localhost:9200"
.\db\experiments\a1-outbox-relay-opensearch-sync\scripts\run-outbox-relay-opensearch-smoke.ps1
```

Optional OpenSearch smoke teardown:

```powershell
docker compose -f db\experiments\a1-opensearch-index-mapping-alias\docker-compose.opensearch-smoke.yml down -v
```

## Expected Result

| metric | expected |
|---|---:|
| processed event count | 5 |
| relay pending event count | 0 |
| failed event count | 1 |
| retry count | 1 |
| idempotent replay mismatch count | 0 |
| duplicate replay count | 0 |
| status-change deleted document count | 0 |
| cleanup old DONE deleted count | 1 |
| cleanup retained FAILED count | 1 |
| cleanup retained recent DONE count | 1 |
| cleanup retained PENDING count | 1 |

## Generated Artifacts

Successful runs write:

```text
results/<timestamp>/outbox-relay-summary.md
results/<timestamp>/relay-processing-result.json
results/<timestamp>/opensearch-upsert-result.json
results/<timestamp>/final-document-result.json
results/<timestamp>/idempotent-replay-result.json
results/<timestamp>/delete-status-change-result.json
results/<timestamp>/failure-scenario-result.json
results/<timestamp>/cleanup-retention-result.json
results/<timestamp>/pending-processed-failed-counts.json
```

If validation fails, the script does not create a pass artifact directory.

## Limitations

- Experiment-level script only; application worker integration remains future work.
- No full backfill or catch-up replay.
- No DB/Search dual-run.
- No API read-path switch.
- No k6 benchmark.
- No production retry scheduler or retention scheduler.

## Next Step

Implement full backfill plus checkpoint/catch-up planning using this relay contract.
