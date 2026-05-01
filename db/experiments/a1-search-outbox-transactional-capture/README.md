# A-1 Search Outbox Transactional Capture

## Purpose

This experiment adds the PostgreSQL `search_outbox` foundation for future product search synchronization.

The previous OpenSearch mapping work selected `options: nested` and validated the local index/query contract. This task does not write to OpenSearch. It proves the database-side transaction boundary that a later relay can consume.

PostgreSQL remains the source of truth.

## Scope

This task includes:

- `search_outbox` schema
- product event type and status contract
- minimal payload contract
- transaction atomicity smoke validation
- commit scenario
- rollback scenario
- product update scenario
- product status-change scenario
- documentation and result artifacts

This task excludes:

- OpenSearch client writes
- relay worker
- event polling worker
- retry worker
- DONE cleanup or retention batch
- full backfill
- catch-up replay
- DB/Search dual-run
- API read-path switch
- k6 or benchmark runs
- Kafka, Debezium, or CDC
- production monitoring or dashboarding

This is not a production readiness or performance claim.

## Schema

Schema file:

```text
db/init/002_create_search_outbox.sql
```

The repository currently uses `db/init` SQL with Docker Compose PostgreSQL initialization. The smoke runner also applies this schema file explicitly so existing local databases can be validated without recreating the PostgreSQL volume.

Minimum columns:

| column | purpose |
|---|---|
| `id` | outbox event identity |
| `aggregate_type` | currently `PRODUCT` |
| `aggregate_id` | affected product id |
| `event_type` | product search event type |
| `schema_version` | event payload contract version |
| `payload` | minimal relay input as `jsonb` |
| `status` | relay state |
| `retry_count` | future retry bookkeeping |
| `last_error` | future failure detail |
| `next_retry_at` | future retry scheduling |
| `created_at` | event creation time |
| `updated_at` | event update time |
| `processed_at` | future terminal processing time |

## Event Contract

Aggregate type:

```text
PRODUCT
```

Event types:

```text
PRODUCT_CREATED
PRODUCT_UPDATED
PRODUCT_DELETED
PRODUCT_STATUS_CHANGED
PRODUCT_OPTION_CHANGED
```

Statuses:

```text
PENDING
PROCESSING
DONE
FAILED
```

Events inserted by product write transactions default to:

```text
PENDING
```

Payload version:

```text
schema_version = 1
```

Minimum payload fields:

| field | purpose |
|---|---|
| `productId` | product document identity |
| `eventType` | event semantic type |
| `sourceUpdatedAt` | source freshness value when available |
| `tombstone` | delete intent marker for future relay deletion |

The payload does not contain the full OpenSearch document. A later relay should load the current source-of-truth product/options rows and build the nested option document.

## Transaction Boundary

The required boundary is:

```sql
BEGIN;
INSERT/UPDATE/DELETE products or product_options;
INSERT INTO search_outbox (...);
COMMIT;
```

If the transaction rolls back, both the product change and the outbox event must disappear.

Because this repository does not currently have a stable product write service path, this task proves the boundary with SQL smoke validation instead of adding a new product write API.

## Delete Policy

Preferred search visibility policy:

- Soft delete or status change is the default product search removal mechanism.
- `PRODUCT_STATUS_CHANGED` is emitted when a product becomes `SOLD_OUT` or `DELETED`.
- Future relay logic can remove or hide the OpenSearch document based on source status.

Hard delete policy:

- If hard delete is required later, insert a `PRODUCT_DELETED` tombstone outbox event before deleting the source row.
- The tombstone event and source delete must be in the same database transaction.
- OpenSearch delete execution belongs to a later relay task, not this task.

## Validation

Start PostgreSQL:

```powershell
docker compose up -d postgres
```

Run the smoke validation:

```powershell
.\db\experiments\a1-search-outbox-transactional-capture\scripts\run-search-outbox-transaction-smoke.ps1
```

The runner:

1. Applies `db/init/002_create_search_outbox.sql`.
2. Deletes only namespaced smoke rows for fixed negative product ids.
3. Commits a product create plus `PRODUCT_CREATED` outbox event.
4. Commits a product update plus `PRODUCT_UPDATED` outbox event.
5. Attempts a product create plus outbox insert, then rolls back.
6. Commits a status change plus `PRODUCT_STATUS_CHANGED` outbox event.
7. Verifies rollback product count and rollback outbox count are both `0`.
8. Writes result artifacts only after all SQL assertions pass.

## Expected Result

| check | expected |
|---|---:|
| committed create product count | 1 |
| create event count | 1 |
| update event count | 1 |
| status-change event count | 1 |
| rollback product count | 0 |
| rollback outbox count | 0 |
| captured event count | 3 |
| pending event count | 3 |

## Generated Artifacts

Successful runs write:

```text
results/<timestamp>/search-outbox-transaction-summary.md
results/<timestamp>/search-outbox-transaction-result.json
results/<timestamp>/commit-scenario-result.json
results/<timestamp>/update-scenario-result.json
results/<timestamp>/rollback-scenario-result.json
results/<timestamp>/status-change-scenario-result.json
results/<timestamp>/pending-event-count-result.json
```

If validation fails, the runner does not create a pass artifact directory.

## Limitations

- SQL smoke only; no application product write service integration exists in this repository yet.
- No relay, polling, retry, cleanup, or OpenSearch write is implemented.
- No product option change smoke is run because the base `product_options` table is profile-specific in this repository.
- No benchmark is run.

## Next Step

Implement an outbox relay that polls `PENDING` events idempotently and writes the nested product document to OpenSearch through the documented write alias.
