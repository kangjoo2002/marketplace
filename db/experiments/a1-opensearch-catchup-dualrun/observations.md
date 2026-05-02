# A-1 OpenSearch Catch-up Dual-run Observations

## Current Status

Local PostgreSQL + OpenSearch catch-up dual-run smoke validation passed.

Generated artifact path:

```text
db/experiments/a1-opensearch-catchup-dualrun/results/20260502_145444/
```

## OpenSearch Index / Alias Setup Result

Pass.

Smoke index and aliases:

```text
products_search_catchup_smoke_v1
products_search_catchup_smoke_read
products_search_catchup_smoke_write
products_search_catchup_smoke_current
```

Catch-up replay wrote through:

```text
products_search_catchup_smoke_write
```

Static shadow comparison read through:

```text
products_search_catchup_smoke_read
```

The target index used the selected nested mapping from:

```text
db/experiments/a1-opensearch-index-mapping-alias/mappings/products_v1_nested.json
```

## Catch-up Replay

Measured high-watermark:

```text
backfill_start_outbox_id = 59
```

Replay predicate:

```text
search_outbox.id > 59
payload->>'smokeRun' = 'opensearch-catchup-dualrun'
```

Observed values:

| metric | value |
|---|---:|
| replayed event count | 3 |
| replay duration ms | 8060 |
| pending after replay | 0 |
| failed after replay | 0 |
| replay batch count | 1 |

Replayed events:

- `PRODUCT_UPDATED`: upserted product `-20002002`
- `PRODUCT_CREATED`: upserted product `-20002000`
- `PRODUCT_STATUS_CHANGED`: deleted product `-20002003` after source status became `DELETED`

## Static Snapshot Comparison

Pass.

Observed values:

| metric | value |
|---|---:|
| dual-run mode | static_shadow_comparison |
| snapshot captured at | 2026-05-02T14:55:07.4857395+09:00 |
| compared query count | 3 |
| mismatch threshold ratio | 0 |
| mismatch count | 0 |
| mismatch ratio | 0 |
| top-k mismatch count | 0 |
| missing in search count | 0 |
| extra in search count | 0 |
| ordering mismatch count | 0 |
| sample diff count | 0 |
| stale by updated_at count | 0 |

Compared scenarios:

- `C1_selective_option_filter`
- `C2_active_status_filter`
- `C3_deleted_exclusion`

Search remained a shadow comparison target only. No API response source was switched.

## Limitations

- Experiment-level script only; application worker integration is not changed.
- Representative scenarios are controlled smoke queries, not the official B1/B2/B3 API benchmark.
- No API read-path switch.
- No feature flag or DB fallback.
- No k6 benchmark.
- No production readiness claim.

## Next Step

Validate lag, fallback, and rollback operations before any API read-path switch.
