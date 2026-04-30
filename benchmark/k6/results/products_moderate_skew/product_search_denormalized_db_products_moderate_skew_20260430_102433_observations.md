# Product Search Denormalized DB API k6 Observation

## Run Identity

| Item | Value |
|---|---|
| Scenario set | `product-search-baseline-v1` |
| Workload version | `product-search-baseline-v1` |
| Profile | `moderate_skew` |
| Read path | Denormalized DB API |
| Endpoint | `GET /api/v1/products/search/denormalized-db` |
| Query shape | PostgreSQL `product_search_documents_moderate_skew` read table, `option_signatures` filter, `OFFSET` pagination |
| App execution mode | Gradle `bootRun` |
| k6 execution mode | local k6 |
| VUs | 10 |
| Warm-up duration | 1m |
| Measured duration | 10m |
| Timestamp | `20260430_102433` |
| API git commit hash | `d77206a70526c782513cd9020e3b91c09ee507c7` |
| Benchmark script git commit hash | not available before commit; script is an uncommitted file on `benchmark/product-search-denormalized-db-api` |
| Official summary JSON | `benchmark/k6/results/products_moderate_skew/product_search_denormalized_db_products_moderate_skew_20260430_102433_summary.json` |

This is a local synthetic `moderate_skew` benchmark result, not a production
capacity claim. API p95 latency must not be compared with PostgreSQL `EXPLAIN`
Execution Time. OpenSearch comparison remains a later stage.

## Benchmark Pre-state

The values below come from the existing corrected read-table artifacts only:

- `db/experiments/a1-product-search-denormalized-read-table/observations.md`
- `db/experiments/a1-product-search-denormalized-read-table/README.md`

No SQL, DB validation, or EXPLAIN was run for this benchmark PR.

| Field | Value |
|---|---|
| read table | `product_search_documents_moderate_skew` |
| backfill started_at | `2026-04-29 05:44:10.314271+00` |
| backfill finished_at | `2026-04-29 05:46:40.158243+00` |
| max document_refreshed_at | `2026-04-29 05:44:10.344209+00` |
| ANALYZE executed_at | `2026-04-29 05:46:39.521126+00` |
| products count | `10000000` |
| product_options count | `20500000` |
| read table count | `10000000` |
| source/read row count match | `true` |
| source/read product_id set match | `true`; missing `0`, extra `0` |
| products_without_options | `0` |
| option_signatures null count | `0` |
| option_signatures empty count | `0` |
| delimiter collision count | `0` |
| signature_count_mismatch | `0` |
| API response field coverage | seller_id/rating/updated_at null and mismatch counts all `0` |
| B1 equivalence | `ids_match = true`, source/read page count `50`, offset `100` |
| B2 equivalence | `ids_match = true`, source/read page count `50`, offset `100` |
| B3 equivalence | `ids_match = true`, source/read page count `50`, offset `10000` |
| read table size | `1832 MB` |
| read table index size | `946 MB` |
| read table total size | `2779 MB` |
| validate-all | not available in existing artifact; explicitly not run |
| multi-offset equivalence | not available in existing artifact; explicitly not run |

## Scenario Constants

| Scenario | Weight | Parameters |
|---|---:|---|
| `B1_selective_option_filter` | 40% | `categoryId=75`, `brandId=943`, `status=ACTIVE`, `minPrice=10000`, `maxPrice=100000`, `color=BLACK`, `size=M`, `stockStatus=IN_STOCK`, `sort=reviewCountDesc`, `limit=50`, `offset=100` |
| `B2_broad_active_option_filter` | 40% | `status=ACTIVE`, `color=BLACK`, `size=M`, `stockStatus=IN_STOCK`, `sort=createdAtDesc`, `limit=50`, `offset=100` |
| `B3_deep_offset_option_filter` | 20% | `categoryId=75`, `brandId=943`, `status=ACTIVE`, `minPrice=10000`, `maxPrice=100000`, `color=BLACK`, `size=M`, `stockStatus=IN_STOCK`, `sort=reviewCountDesc`, `limit=50`, `offset=10000` |

The measured run reused the deterministic sequence `[B1, B1, B2, B2, B3]`.
Trend metric names were unchanged:

- `b1_selective_option_filter_duration`
- `b2_broad_active_option_filter_duration`
- `b3_deep_offset_option_filter_duration`

## HTTP Smoke

One B1 HTTP smoke request was run against:

```powershell
Invoke-RestMethod -Uri 'http://localhost:8080/api/v1/products/search/denormalized-db?categoryId=75&brandId=943&status=ACTIVE&minPrice=10000&maxPrice=100000&color=BLACK&size=M&stockStatus=IN_STOCK&sort=reviewCountDesc&limit=50&offset=100' -Method Get
```

Result: pass.

| Field | Value |
|---|---:|
| HTTP status | 200 |
| items length | 50 |
| page.limit | 50 |
| page.offset | 100 |
| page.returnedCount | 50 |

HTTP smoke is not an official benchmark result.

## k6 Smoke

Command:

```powershell
$env:PROFILE='moderate_skew'
$env:BASE_URL='http://localhost:8080'
$env:VUS='10'
$env:DURATION='1s'
$env:SMOKE_ONLY='true'
Remove-Item Env:SUMMARY_JSON -ErrorAction SilentlyContinue
& 'C:\Program Files\k6\k6.exe' run benchmark\k6\product-search-denormalized-db.js
```

Result: pass, exit code 0, failed checks 0. k6 smoke is not an official
benchmark result.

## Warm-up

Command:

```powershell
$env:PROFILE='moderate_skew'
$env:BASE_URL='http://localhost:8080'
$env:VUS='10'
$env:DURATION='1m'
$env:SMOKE_ONLY='false'
Remove-Item Env:SUMMARY_JSON -ErrorAction SilentlyContinue
& 'C:\Program Files\k6\k6.exe' run --quiet benchmark\k6\product-search-denormalized-db.js
```

Result: pass, exit code 0, error rate 0, failed checks 0. Warm-up is excluded
from official results.

## Measured Run

Command:

```powershell
$timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$env:PROFILE='moderate_skew'
$env:BASE_URL='http://localhost:8080'
$env:VUS='10'
$env:DURATION='10m'
$env:SMOKE_ONLY='false'
$env:SUMMARY_JSON="benchmark\k6\results\products_moderate_skew\product_search_denormalized_db_products_moderate_skew_${timestamp}_summary.json"
& 'C:\Program Files\k6\k6.exe' run --quiet benchmark\k6\product-search-denormalized-db.js
```

| Metric | Value |
|---|---:|
| Mixed p95 | 127.34185999999998 ms |
| B1 p95 | 20.867624999999993 ms |
| B2 p95 | 23.145569999999992 ms |
| B3 p95 | 152.9373 ms |
| Throughput | 276.1365354515421 req/s |
| Error rate | 0 |
| Failed checks | 0 |
| Checks rate | 1 |
| Total requests | 165685 |

## Optional Extra Metrics

The generated k6 summary JSON includes p90 values but does not include p99
values.

| Metric | Value |
|---|---:|
| Mixed p90 | 120.5948 ms |
| B1 p90 | 16.78818 ms |
| B2 p90 | 18.658920000000002 ms |
| B3 p90 | 139.6441 ms |
| p99 | not available in generated summary JSON |

## Checks Summary

All copied DB tuned response checks passed.

| Scenario | Iterations | Failed checks |
|---|---:|---:|
| B1 | 66282 | 0 |
| B2 | 66272 | 0 |
| B3 | 33131 | 0 |

Checks included HTTP 200, `items` array shape, `items.length == limit`, page
presence, page limit/offset matching, numeric returnedCount, returnedCount > 0,
returnedCount == limit, and returnedCount <= limit.

## Comparison Table

Comparison sources:

```text
benchmark/k6/results/products_moderate_skew/product_search_baseline_products_moderate_skew_20260428_115844_summary.json
benchmark/k6/results/products_moderate_skew/product_search_db_tuned_products_moderate_skew_20260428_150401_summary.json
benchmark/k6/results/products_moderate_skew/product_search_denormalized_db_products_moderate_skew_20260430_102433_summary.json
```

| Read path | Total requests | Mixed p95 | B1 p95 | B2 p95 | B3 p95 | Throughput | Error rate | Failed checks |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| Baseline API | 382 | 29611.602365 ms | 17124.170814999994 ms | 33409.19112499999 ms | 18519.306105 ms | 0.6262291702382904 req/s | 0 | 0 |
| DB tuned API | 31126 | 370.313125 ms | 386.7013 ms | 33.930324999999996 ms | 394.51556999999997 ms | 51.85398922328235 req/s | 0 | 0 |
| Denormalized DB API | 165685 | 127.34185999999998 ms | 20.867624999999993 ms | 23.145569999999992 ms | 152.9373 ms | 276.1365354515421 req/s | 0 | 0 |

## Query-shape Context

The query-shape context below comes from existing read-table validation and
EXPLAIN artifacts only. No EXPLAIN was run for this benchmark PR.

- The Denormalized DB API reads from `product_search_documents_moderate_skew`.
- The Denormalized DB API avoids a read-time join back to `products_moderate_skew`.
- The Denormalized DB API avoids a read-time `product_options_moderate_skew` join or `EXISTS`.
- Option filtering uses `option_signatures`.
- Previous read-table EXPLAIN observed no `Sort` node for B1/B2/B3.
- Previous read-table EXPLAIN observed that option GIN was not used and the option predicate remained a residual filter.
- B3 deep `OFFSET` remains a workload limitation.
- Freshness remains rebuild-only; no trigger, outbox, CDC, relay, worker, queue, API write-path hook, or real-time synchronization is implemented.

## Interpretation

The Denormalized DB API removes read-time joins back to the normalized source
tables (`products_moderate_skew` and `product_options_moderate_skew`) for this
benchmark endpoint. It still depends on the PostgreSQL read table
`product_search_documents_moderate_skew` and OFFSET pagination. This is not
OpenSearch and does not prove production capacity.

OpenSearch remains a later stage.
