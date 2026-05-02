# A-1 OpenSearch Backfill Checkpoint Observations

## Current Status

Local PostgreSQL + OpenSearch backfill checkpoint smoke validation passed.

Generated artifact path:

```text
db/experiments/a1-opensearch-backfill-checkpoint/results/20260502_112733/
```

## OpenSearch Index / Alias Setup Result

Pass.

Smoke index and aliases:

```text
products_search_backfill_smoke_v1
products_search_backfill_smoke_read
products_search_backfill_smoke_write
products_search_backfill_smoke_current
```

The backfill wrote through:

```text
products_search_backfill_smoke_write
```

## Backfill High-watermark

Measured before backfill start:

```text
backfill_start_outbox_id = 59
```

Future catch-up replay predicate:

```text
search_outbox.id > 59
```

## Counts

Observed values:

| metric | value |
|---|---:|
| source product count | 4 |
| indexed document count | 4 |
| missing document count | 0 |
| extra document count | 0 |
| sample document comparison count | 3 |
| sample document mismatch count | 0 |
| failed batch count | 0 |
| retried batch count | 0 |
| backfill duration ms | 8027 |
| backfill throughput products/sec | 0.498 |

## Checkpoint / Resume

Pass.

Observed:

| metric | value |
|---|---:|
| batch size | 2 |
| checkpoint position after interruption | -19002003 |
| final checkpoint position | -19002001 |
| partial batch count | 1 |
| resumed batch count | 1 |
| resume success | true |

## Limitations

- No catch-up replay.
- No DB/Search dual-run.
- No API read-path switch.
- No k6 benchmark.

## Next Step

Implement catch-up replay plus DB/Search dual-run verification.
