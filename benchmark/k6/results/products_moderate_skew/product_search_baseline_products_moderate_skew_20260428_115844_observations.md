# Product Search Baseline API k6 Observation

## Run Identity

| Item | Value |
|---|---|
| Scenario set | `product-search-baseline-v1` |
| Profile | `moderate_skew` |
| Baseline API path | `products + product_options JOIN + DISTINCT + OFFSET` |
| Endpoint | `GET /api/v1/products/search` |
| Application table pair | `products_moderate_skew`, `product_options_moderate_skew` |
| App execution mode | Gradle `bootRun` |
| k6 execution mode | local k6 |
| VUs | 10 |
| Warm-up duration | 1m |
| Measured duration | 10m |
| Official summary JSON | `benchmark/k6/results/products_moderate_skew/product_search_baseline_products_moderate_skew_20260428_115844_summary.json` |

This is a local synthetic benchmark result, not a production capacity claim.
API p95 latency must not be compared with PostgreSQL `EXPLAIN` Execution Time.

The earlier 1-minute run is retained as an initial pilot/superseded local
measured run because it produced only 47 requests. This 10-minute run is the
official representative Baseline API artifact for `moderate_skew`.

The earlier `OUT_OF_STOCK` artifacts were invalid and discarded. `uniform` and
`high_skew` were not measured in this PR.

## Scenario Constants

| Scenario | Weight | Parameters |
|---|---:|---|
| `B1_selective_option_filter` | 40% | `categoryId=75`, `brandId=943`, `status=ACTIVE`, `minPrice=10000`, `maxPrice=100000`, `color=BLACK`, `size=M`, `stockStatus=IN_STOCK`, `sort=reviewCountDesc`, `limit=50`, `offset=100` |
| `B2_broad_active_option_filter` | 40% | `status=ACTIVE`, `color=BLACK`, `size=M`, `stockStatus=IN_STOCK`, `sort=createdAtDesc`, `limit=50`, `offset=100` |
| `B3_deep_offset_option_filter` | 20% | `categoryId=75`, `brandId=943`, `status=ACTIVE`, `minPrice=10000`, `maxPrice=100000`, `color=BLACK`, `size=M`, `stockStatus=IN_STOCK`, `sort=reviewCountDesc`, `limit=50`, `offset=10000` |

B1 and B3 are the same selective product-search workload. They use the same
filters, sort, and limit; only `offset` differs. B3 keeps `offset=10000` to
exercise the baseline deep OFFSET path.

B2 is intentionally broad and can influence the mixed p95. Interpret the mixed
p95 together with scenario-level p95 values.

## SQL Validation

Validation used `COUNT(DISTINCT p.id)`, not raw option rows.

| Scenario | matching_count | required_min_count | Passes |
|---|---:|---:|---|
| B1/B3 selected candidate | 13380 | 10050 | true |
| B2 broad active option filter | 720000 | 150 | true |

Command:

```powershell
@'
SELECT 'B1_B3_selected_candidate' AS scenario,
       COUNT(DISTINCT p.id) AS matching_count,
       10050 AS required_min_count,
       COUNT(DISTINCT p.id) >= 10050 AS passes
FROM products_moderate_skew p
JOIN product_options_moderate_skew po ON po.product_id = p.id
WHERE p.category_id = 75
  AND p.brand_id = 943
  AND p.status = 'ACTIVE'
  AND p.price BETWEEN 10000 AND 100000
  AND po.color = 'BLACK'
  AND po.size = 'M'
  AND po.stock_status = 'IN_STOCK'
UNION ALL
SELECT 'B2_broad_active_option_filter',
       COUNT(DISTINCT p.id),
       150,
       COUNT(DISTINCT p.id) >= 150
FROM products_moderate_skew p
JOIN product_options_moderate_skew po ON po.product_id = p.id
WHERE p.status = 'ACTIVE'
  AND po.color = 'BLACK'
  AND po.size = 'M'
  AND po.stock_status = 'IN_STOCK';
'@ | docker compose exec -T postgres psql -U readpath -d readpath_lab
```

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
& 'C:\Program Files\k6\k6.exe' run benchmark\k6\product-search-baseline.js
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
& 'C:\Program Files\k6\k6.exe' run benchmark\k6\product-search-baseline.js
```

Warm-up is excluded from official results.

## Measured Run

Command:

```powershell
$env:PROFILE='moderate_skew'
$env:BASE_URL='http://localhost:8080'
$env:VUS='10'
$env:DURATION='10m'
$env:SMOKE_ONLY='false'
$env:SUMMARY_JSON='benchmark\k6\results\products_moderate_skew\product_search_baseline_products_moderate_skew_20260428_115844_summary.json'
& 'C:\Program Files\k6\k6.exe' run benchmark\k6\product-search-baseline.js
```

| Metric | Value |
|---|---:|
| Mixed p95 | 29611.602365 ms |
| B1 p95 | 17124.170814999994 ms |
| B2 p95 | 33409.19112499999 ms |
| B3 p95 | 18519.306105 ms |
| Throughput | 0.6262291702382904 req/s |
| Error rate | 0 |
| Failed checks | 0 |
| Checks rate | 1 |
| Total requests | 382 |

