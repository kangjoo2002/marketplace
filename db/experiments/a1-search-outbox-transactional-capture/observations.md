# Search Outbox Transactional Capture Observations

## Current Status

Local PostgreSQL smoke validation passed.

Generated artifact path:

```text
db/experiments/a1-search-outbox-transactional-capture/results/20260501_235850/
```

## Migration / Schema Result

Pass.

Schema file:

```text
db/init/002_create_search_outbox.sql
```

The smoke runner applied the schema against:

```text
docker compose postgres/readpath_lab
```

## Transaction Atomicity Check

Pass.

The smoke SQL validated:

- committed product write and outbox insert both persisted
- rolled-back product write and outbox insert both disappeared
- rollback outbox count was `0`

## Commit Scenario Result

Pass.

Observed:

| metric | value |
|---|---:|
| product id | -17001001 |
| committed product count | 1 |
| create event count | 1 |
| create event status | PENDING |

## Update Scenario Result

Pass.

Observed:

| metric | value |
|---|---:|
| product id | -17001001 |
| committed price | 35900 |
| update event count | 1 |
| update event status | PENDING |

## Rollback Scenario Result

Pass.

Observed:

| metric | value |
|---|---:|
| product id | -17001002 |
| rollback product count | 0 |
| rollback outbox count | 0 |

## Status-change Scenario Result

Pass.

Observed:

| metric | value |
|---|---:|
| product id | -17001001 |
| committed status | DELETED |
| status-change event count | 1 |
| status-change event status | PENDING |

## Counts

Observed values:

| metric | value |
|---|---:|
| create event count | 1 |
| update event count | 1 |
| status-change event count | 1 |
| rollback outbox count | 0 |
| pending event count | 3 |
| captured event count | 3 |

## Outbox Contract

Documented in `README.md`.

## Delete Policy

Soft delete/status change is the preferred search visibility policy. Hard delete requires a tombstone outbox event inserted before deleting the source row in the same transaction.

## Limitations

- Application product write-path integration remains future work because this repository currently contains product search read paths, not a stable product write service.
- OpenSearch is not written in this task.
- Relay is not implemented in this task.
- No benchmark is run.

## Next Step

Implement an outbox relay that polls `PENDING` events idempotently and writes the nested product document to OpenSearch through the documented write alias.
