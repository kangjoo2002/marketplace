# Product Search Baseline API Observations

- scenario set version: `product-search-baseline-v1`
- profile: `moderate_skew`
- Baseline API path: products + product_options
- endpoint: `GET /api/v1/products/search`
- query shape: `products + product_options JOIN + DISTINCT + OFFSET`
- application products table: `products_moderate_skew`
- application product_options table: `product_options_moderate_skew`
- app execution mode: Gradle `bootRun`
- k6 execution mode: local
- VUs: 10
- warm-up duration: 30s
- measured duration: 1m
- official summary JSON: `benchmark/k6/results/products_moderate_skew/product_search_baseline_products_moderate_skew_20260428_105518_summary.json`

## Scenario Constants

| Scenario | Weight | Parameters |
|---|---:|---|
| `B1_selective_option_filter` | 40% | `categoryId=75`, `brandId=943`, `status=ACTIVE`, `minPrice=10000`, `maxPrice=100000`, `color=BLACK`, `size=M`, `stockStatus=IN_STOCK`, `sort=reviewCountDesc`, `limit=50`, `offset=100` |
| `B2_broad_active_option_filter` | 40% | `status=ACTIVE`, `color=BLACK`, `size=M`, `stockStatus=IN_STOCK`, `sort=createdAtDesc`, `limit=50`, `offset=100` |
| `B3_deep_offset_option_filter` | 20% | `categoryId=75`, `brandId=943`, `status=ACTIVE`, `minPrice=10000`, `maxPrice=100000`, `color=BLACK`, `size=M`, `stockStatus=IN_STOCK`, `sort=reviewCountDesc`, `limit=50`, `offset=10000` |

B1 and B3 are paired shallow/deep pages of the same selective workload. They use
the same filters, sort, and limit; only `offset` differs. B3 keeps
`offset=10000` to preserve the deep OFFSET API baseline shape.

B2 is intentionally broad. It may influence mixed p95, so scenario-level p95 is
reported with the mixed p95.

## SQL Validation

Validation used `COUNT(DISTINCT p.id)`, not raw option rows.

| Scenario | matching_count | required_min_count | Passes |
|---|---:|---:|---|
| B1/B3 selected candidate | 13380 | 10050 | true |
| B2 broad active option filter | 720000 | 150 | true |

## Smoke Checks

HTTP smoke command shape:

```powershell
Invoke-WebRequest -Uri "http://localhost:8080/api/v1/products/search?...scenario params..." -UseBasicParsing -TimeoutSec 180
```

| Scenario | HTTP status | page.limit | page.offset | returnedCount | items length | Passes |
|---|---:|---:|---:|---:|---:|---|
| B1 | 200 | 50 | 100 | 50 | 50 | true |
| B2 | 200 | 50 | 100 | 50 | 50 | true |
| B3 | 200 | 50 | 10000 | 50 | 50 | true |

k6 smoke command:

```powershell
$env:PROFILE='moderate_skew'; $env:BASE_URL='http://localhost:8080'; $env:VUS='10'; $env:DURATION='1s'; $env:SMOKE_ONLY='true'; Remove-Item Env:SUMMARY_JSON -ErrorAction SilentlyContinue; & 'C:\Program Files\k6\k6.exe' run benchmark\k6\product-search-baseline.js
```

k6 smoke result: passed, failed checks `0`.

## Run Commands

Warm-up command:

```powershell
$env:PROFILE='moderate_skew'; $env:BASE_URL='http://localhost:8080'; $env:VUS='10'; $env:DURATION='30s'; $env:SMOKE_ONLY='false'; Remove-Item Env:SUMMARY_JSON -ErrorAction SilentlyContinue; & 'C:\Program Files\k6\k6.exe' run benchmark\k6\product-search-baseline.js
```

Measured command:

```powershell
$env:PROFILE='moderate_skew'; $env:BASE_URL='http://localhost:8080'; $env:VUS='10'; $env:DURATION='1m'; $env:SMOKE_ONLY='false'; $env:SUMMARY_JSON='benchmark\k6\results\products_moderate_skew\product_search_baseline_products_moderate_skew_20260428_105518_summary.json'; & 'C:\Program Files\k6\k6.exe' run benchmark\k6\product-search-baseline.js
```

Warm-up results are excluded from the official artifact. The measured summary
JSON is the official artifact.

## Results

| Metric | Value |
|---|---:|
| mixed p95 | 30072.52516 ms |
| B1 p95 | 14599.097754999997 ms |
| B2 p95 | 30346.642174999997 ms |
| B3 p95 | 14949.42864 ms |
| throughput | 0.6905980896102596 req/s |
| error rate | 0 |
| failed checks | 0 |
| checks rate | 1 |
| requests | 47 |

## Notes

- Previous `OUT_OF_STOCK` artifacts were invalid and discarded.
- This is a local synthetic benchmark, not a production capacity claim.
- API p95 must not be compared with PostgreSQL `EXPLAIN` Execution Time.
- `PROFILE` in k6 is metadata/tagging only. The actual API table pair is
  selected by Spring application properties.
- `uniform` and `high_skew` are deferred and were not measured in this run.
