# A-1 Outbox Relay OpenSearch Sync Observations

## Current Status

Local PostgreSQL + OpenSearch relay smoke validation passed.

Generated artifact path:

```text
db/experiments/a1-outbox-relay-opensearch-sync/results/20260502_111326/
```

## Relay Smoke Result

Pass.

The relay processed namespaced `PENDING` events, claimed them as `PROCESSING`, and moved successful events to `DONE`.

## OpenSearch Index / Alias Setup Result

Pass.

Smoke index and aliases:

```text
products_search_relay_smoke_v1
products_search_relay_smoke_read
products_search_relay_smoke_write
products_search_relay_smoke_current
```

The relay wrote through:

```text
products_search_relay_smoke_write
```

## Counts

Observed values:

| metric | value |
|---|---:|
| processed event count | 5 |
| pending event count | 0 |
| failed event count | 1 |
| retry count | 1 |
| oldest pending age seconds | 864002.054 |
| relay batch duration ms | 13508 |
| idempotent replay mismatch count | 0 |
| duplicate replay count | 0 |
| cleaned DONE event count | 1 |

`oldest pending age seconds` is measured from namespaced smoke retention data, including an intentionally retained old `PENDING` row. It is not an operational relay lag metric.

## Delete / Status-change Handling

Policy: `PRODUCT_STATUS_CHANGED` deletes the OpenSearch document when source status is `DELETED`.

Validated.

Observed:

| metric | value |
|---|---:|
| product id | -18002002 |
| source status | DELETED |
| OpenSearch document count after relay | 0 |

## Failure Scenario

Pass.

The smoke processed one event with an invalid OpenSearch URL.

Observed:

| metric | value |
|---|---:|
| failed event count | 1 |
| retry count | 1 |
| last_error present count | 1 |
| failed event preserved | yes |

## DONE Retention

Policy: delete only old `DONE` events older than 7 days. Retain recent `DONE`, `FAILED`, and `PENDING`.

Validated.

Observed:

| metric | value |
|---|---:|
| retention days | 7 |
| cleaned old DONE event count | 1 |
| retained recent DONE count | 1 |
| retained FAILED count | 1 |
| retained PENDING count | 1 |

## Limitations

- No application worker integration yet.
- No backfill or catch-up replay.
- No API read-path switch.
- No k6 benchmark.

## Next Step

Implement full backfill plus checkpoint/catch-up planning using this relay contract.
