# Product Search DB Tuned API k6 Observation

## Run Identity

| Item | Value |
|---|---|
| Scenario set | `product-search-baseline-v1` |
| Workload version | `product-search-baseline-v1` |
| Profile | `moderate_skew` |
| Read path | DB tuned API |
| Endpoint | `GET /api/v1/products/search/db-tuned` |
| Query shape | PostgreSQL-backed `products` + `product_options`, `EXISTS` option filtering, no `SELECT DISTINCT`, `OFFSET` pagination |
| Application table pair | `products_moderate_skew`, `product_options_moderate_skew` |
| App execution mode | Gradle `bootRun` |
| k6 execution mode | local k6 |
| VUs | 10 |
| Warm-up duration | 1m |
| Measured duration | 10m |
| Official summary JSON | `benchmark/k6/results/products_moderate_skew/product_search_db_tuned_products_moderate_skew_20260428_150401_summary.json` |

This is selected supporting indexes + `EXISTS` combined DB tuned path
measurement, not an `EXISTS`-only improvement measurement.

This is local synthetic benchmark data, not a production capacity claim.
API p95 latency is not compared with PostgreSQL `EXPLAIN` Execution Time.
`uniform` and `high_skew` were not measured. Denormalized DB and OpenSearch are
later stages.

## Selected Supporting Indexes

The selected indexes were added only for `products_moderate_skew` and
`product_options_moderate_skew` by `db/setup/a1-product-search-db-tuned-indexes.sql`.
No selected indexes were added for `uniform` or `high_skew` profile tables.

```sql
CREATE INDEX IF NOT EXISTS idx_products_moderate_skew_active_cat_brand_review
ON products_moderate_skew(category_id, brand_id, review_count DESC, id DESC)
WHERE status = 'ACTIVE';

CREATE INDEX IF NOT EXISTS idx_products_moderate_skew_active_created
ON products_moderate_skew(created_at DESC, id DESC)
WHERE status = 'ACTIVE';

CREATE INDEX IF NOT EXISTS idx_product_options_moderate_skew_color_size_stock_product
ON product_options_moderate_skew(color, size, stock_status, product_id);
```

Index rationale:

- B1/B3 products index prioritizes `reviewCountDesc` ordering.
- B1/B3 price remains a residual filter by design.
- Price is not placed before `review_count` because prior products experiments
  showed that range columns before ordering columns can leave explicit sort work.
- B2 products index targets broad ACTIVE `createdAtDesc` listing.
- `product_options` uses option-filter-first because the workload includes B2
  broad option filtering, and DB-only artifacts showed option-filter-first is
  more defensible for that broad case.

## Scenario Constants

| Scenario | Weight | Parameters |
|---|---:|---|
| `B1_selective_option_filter` | 40% | `categoryId=75`, `brandId=943`, `status=ACTIVE`, `minPrice=10000`, `maxPrice=100000`, `color=BLACK`, `size=M`, `stockStatus=IN_STOCK`, `sort=reviewCountDesc`, `limit=50`, `offset=100` |
| `B2_broad_active_option_filter` | 40% | `status=ACTIVE`, `color=BLACK`, `size=M`, `stockStatus=IN_STOCK`, `sort=createdAtDesc`, `limit=50`, `offset=100` |
| `B3_deep_offset_option_filter` | 20% | `categoryId=75`, `brandId=943`, `status=ACTIVE`, `minPrice=10000`, `maxPrice=100000`, `color=BLACK`, `size=M`, `stockStatus=IN_STOCK`, `sort=reviewCountDesc`, `limit=50`, `offset=10000` |

B1 and B3 use the same filters, sort, and limit; only `offset` differs. B3
keeps `offset=10000`. B2 is intentionally broad and can influence mixed p95, so
scenario-level p95 should be read alongside mixed p95.

`PROFILE` in k6 is metadata/tagging only. The actual API table pair is selected
by Spring application properties.

## SQL Validation

Validation reused the official Baseline API count shape with
`COUNT(DISTINCT p.id)`, not raw option rows.

| Scenario | matching_count | required_min_count | Passes |
|---|---:|---:|---|
| B1/B3 selected candidate | 13380 | 10050 | true |
| B2 broad active option filter | 720000 | 150 | true |

## EXPLAIN Sanity Check Summary

The sanity check used the DB tuned `EXISTS` query shape for B1/B2/B3 against
`products_moderate_skew` and `product_options_moderate_skew`.

| Scenario | Products index observation | product_options index observation | DISTINCT/Unique | Price residual filter |
|---|---|---|---|---|
| B1 | `idx_products_moderate_skew_active_cat_brand_review` was used through `Bitmap Index Scan`; a `Sort` node remained for `review_count DESC, id DESC` | `idx_product_options_moderate_skew_color_size_stock_product` was used through `Index Only Scan` | No `SELECT DISTINCT`; no `Unique` node | `p.price >= 10000 AND p.price <= 100000` remained a `Filter` |
| B2 | `idx_products_moderate_skew_active_created` was used through ordered `Index Scan` | `idx_product_options_moderate_skew_color_size_stock_product` was used through `Index Only Scan` | No `SELECT DISTINCT`; no `Unique` node | Not applicable; B2 has no price filter |
| B3 | `idx_products_moderate_skew_active_cat_brand_review` was used through `Bitmap Index Scan`; a `Sort` node remained for `review_count DESC, id DESC` | `idx_product_options_moderate_skew_color_size_stock_product` was used through `Index Only Scan` | No `SELECT DISTINCT`; no `Unique` node | `p.price >= 10000 AND p.price <= 100000` remained a `Filter` |

## HTTP Smoke

| Scenario | HTTP status | page.limit | page.offset | returnedCount | items length | Result |
|---|---:|---:|---:|---:|---:|---|
| B1 | 200 | 50 | 100 | 50 | 50 | pass |
| B2 | 200 | 50 | 100 | 50 | 50 | pass |
| B3 | 200 | 50 | 10000 | 50 | 50 | pass |

## k6 Smoke

Command:

```powershell
$env:PROFILE='moderate_skew'
$env:BASE_URL='http://localhost:8080'
$env:VUS='10'
$env:DURATION='1s'
$env:SMOKE_ONLY='true'
Remove-Item Env:SUMMARY_JSON -ErrorAction SilentlyContinue
& 'C:\Program Files\k6\k6.exe' run benchmark\k6\product-search-db-tuned.js
```

Result: pass, exit code 0, failed checks 0.

## Warm-up

Command:

```powershell
$env:PROFILE='moderate_skew'
$env:BASE_URL='http://localhost:8080'
$env:VUS='10'
$env:DURATION='1m'
$env:SMOKE_ONLY='false'
Remove-Item Env:SUMMARY_JSON -ErrorAction SilentlyContinue
& 'C:\Program Files\k6\k6.exe' run --quiet benchmark\k6\product-search-db-tuned.js
```

Warm-up is excluded from official results. The rerun warm-up completed with
error rate 0, failed checks 0, and 3414 total requests.

## Measured Run

Command:

```powershell
$env:PROFILE='moderate_skew'
$env:BASE_URL='http://localhost:8080'
$env:VUS='10'
$env:DURATION='10m'
$env:SMOKE_ONLY='false'
$env:SUMMARY_JSON='benchmark\k6\results\products_moderate_skew\product_search_db_tuned_products_moderate_skew_20260428_150401_summary.json'
& 'C:\Program Files\k6\k6.exe' run --quiet benchmark\k6\product-search-db-tuned.js
```

| Metric | Value |
|---|---:|
| Mixed p95 | 370.313125 ms |
| B1 p95 | 386.7013 ms |
| B2 p95 | 33.930324999999996 ms |
| B3 p95 | 394.51556999999997 ms |
| Throughput | 51.85398922328235 req/s |
| Error rate | 0 |
| Failed checks | 0 |
| Checks rate | 1 |
| Total requests | 31126 |

## Baseline Comparison

Comparison target:

```text
benchmark/k6/results/products_moderate_skew/product_search_baseline_products_moderate_skew_20260428_115844_summary.json
```

Both runs use the same `product-search-baseline-v1` `moderate_skew` workload,
same B1/B2/B3 constants, same 40/40/20 weights, same 10 VUs, same 1m warm-up,
same 10m measured duration, same local k6 mode, and same Spring application
table pair.

| Read path | Total requests | Mixed p95 | B1 p95 | B2 p95 | B3 p95 | Throughput | Error rate | Failed checks |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| Baseline API | 382 | 29611.602365 ms | 17124.170814999994 ms | 33409.19112499999 ms | 18519.306105 ms | 0.6262291702382904 req/s | 0 | 0 |
| DB tuned API | 31126 | 370.313125 ms | 386.7013 ms | 33.930324999999996 ms | 394.51556999999997 ms | 51.85398922328235 req/s | 0 | 0 |

The DB tuned measurement should be interpreted as a combined PostgreSQL
normalized read path result for selected indexes + `EXISTS` option filtering +
DISTINCT removal + OFFSET pagination. It is not a keyset pagination result and
does not answer Denormalized DB, OpenSearch, Redis/cache, or production capacity.
