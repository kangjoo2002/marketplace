# Search Outbox Transaction Smoke Summary

- DB target: docker compose postgres/readpath_lab
- Schema status: applied
- Transaction atomicity: pass
- Final smoke status: pass

| metric | value |
|---|---:|
| committed create product count | 1 |
| create event count | 1 |
| update event count | 1 |
| status-change event count | 1 |
| rollback product count | 0 |
| rollback outbox count | 0 |
| captured event count | 3 |
| pending event count | 3 |

Selected policy: soft delete/status change is the default search visibility mechanism; hard delete requires a tombstone event inserted before deleting the source row in the same transaction.

This smoke result is not a benchmark or production readiness claim.
