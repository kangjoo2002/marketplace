# Product Search k6 Baseline, DB Tuned, and Denormalized DB API

This benchmark measures product search APIs as black-box HTTP endpoints. It does
not measure PostgreSQL `EXPLAIN` execution time and does not collect internal
application timers.

Target endpoints:

```http
GET /api/v1/products/search
GET /api/v1/products/search/db-tuned
GET /api/v1/products/search/denormalized-db
```

Benchmark scripts:

```text
benchmark/k6/product-search-baseline.js
benchmark/k6/product-search-db-tuned.js
benchmark/k6/product-search-denormalized-db.js
```

Baseline query shape under the API:

```text
products + product_options
JOIN + DISTINCT
OFFSET pagination
```

DB tuned query shape under the API:

```text
products + product_options
EXISTS option filtering
no SELECT DISTINCT where EXISTS makes DISTINCT unnecessary
OFFSET pagination
```

Denormalized DB query shape under the API:

```text
product_search_documents_moderate_skew
option_signatures filter
OFFSET pagination
```

The DB tuned API keeps PostgreSQL as the backing store and keeps the normalized
products/product_options schema. It measures selected supporting indexes +
`EXISTS` option filtering + DISTINCT removal + OFFSET pagination as a combined
DB tuned path, not an `EXISTS`-only improvement.

The Denormalized DB API keeps PostgreSQL as the backing store and reads from the
`product_search_documents_moderate_skew` read table. This benchmark does not
use or assume keyset pagination, OpenSearch, Redis, caching, outbox, or
`totalCount`.

## Environment

This PR finalizes only the `moderate_skew` Baseline API benchmark.
`moderate_skew` is the representative A-1 profile. `uniform` and `high_skew`
are deferred auxiliary profile-specific workload comparisons. Strict
fixed-query distribution sensitivity is excluded from this PR.

Documented benchmark line:

| Item | Value |
|---|---|
| Machine | SAMSUNG ELECTRONICS CO., LTD. 950XDC/951XDC/950XDX |
| CPU | 11th Gen Intel(R) Core(TM) i7-1165G7 @ 2.80GHz |
| Logical processors | 8 |
| Memory | 16,837,255,168 bytes, approximately 15.68 GiB |
| OS | Windows 10 Home 25H2, build 26200.8246 |
| Architecture | AMD64 |
| Docker | Docker client 26.1.4, build 5650f9b |
| Docker Compose | v2.27.1-desktop.1 |
| Docker Desktop | 4.31.1.153621 |
| Docker Desktop CPU limit | 8 |
| Docker Desktop memory limit | 4096 MiB |
| Docker Desktop swap | 1024 MiB |
| Docker Desktop disk image size | 65536 MiB |
| PostgreSQL container | `readpath-postgres`, `postgres:16`, running/healthy |
| PostgreSQL container shared memory | `shm_size: "1g"` |
| Database | `readpath_lab` |
| Docker Compose postgres service | `postgres` |
| PostgreSQL server version | PostgreSQL 16.13 |
| Java | 21.0.9 LTS |
| Gradle | 8.14.4 wrapper configured |
| Spring Boot app execution mode | Gradle `bootRun` |
| k6 | v1.7.1, installed through `winget install --id GrafanaLabs.k6 --exact` |

Docker Desktop memory must be set to 4096 MiB for this benchmark line. Do not
silently run official measurements under a different Docker memory setting. If
Docker resources, app execution mode, dataset profile, or k6 scenario version
changes, do not compare the results without remeasuring.

This is a local synthetic benchmark and is not a production capacity claim.

Verified local Docker state for the first measured artifact:

- Docker Desktop `settings.json` memory: 4096 MiB
- Docker engine reported memory: 4,110,450,688 bytes
- The engine-reported value is lower than 4096 MiB because of WSL2 overhead.
- PostgreSQL container shared memory: 1,073,741,824 bytes

## Scenario Set

The earlier local run that used `stockStatus=OUT_OF_STOCK` for all B1/B2/B3
scenarios is invalid and discarded. Those summary JSON and observations files
are not official baseline artifacts.

Scenario set name/version:

```text
product-search-baseline-v1
```

The scenario set is fixed and must be reused for future baseline API, DB tuned
API, denormalized DB API, and OpenSearch API measurements unless a new scenario
version is explicitly introduced.

| Scenario | Weight | Purpose | Request parameters |
|---|---:|---|---|
| `B1_selective_option_filter` | 40% | Selective category and brand product search with price and option filters | `categoryId=75`, `brandId=943`, `status=ACTIVE`, `minPrice=10000`, `maxPrice=100000`, `color=BLACK`, `size=M`, `stockStatus=IN_STOCK`, `sort=reviewCountDesc`, `limit=50`, `offset=100` |
| `B2_broad_active_option_filter` | 40% | Broad active-product option-filtered listing | `status=ACTIVE`, `color=BLACK`, `size=M`, `stockStatus=IN_STOCK`, `sort=createdAtDesc`, `limit=50`, `offset=100` |
| `B3_deep_offset_option_filter` | 20% | Deeper page of the same selective category and brand product search as B1 | `categoryId=75`, `brandId=943`, `status=ACTIVE`, `minPrice=10000`, `maxPrice=100000`, `color=BLACK`, `size=M`, `stockStatus=IN_STOCK`, `sort=reviewCountDesc`, `limit=50`, `offset=10000` |

B1 and B3 use the same filters, sort, and limit; only `offset` differs. B3 keeps
`offset=10000` for the deep OFFSET baseline.

`PROFILE` in k6 is metadata/tagging only. The actual API table pair is selected
by Spring application properties.

SQL validation for the official `moderate_skew` run used
`COUNT(DISTINCT p.id)`, not raw option rows:

| Scenario | matching_count | required_min_count | Passes |
|---|---:|---:|---|
| B1/B3 selected candidate | 13380 | 10050 | true |
| B2 broad active option filter | 720000 | 150 | true |

Validation command shape:

```powershell
docker compose exec -T postgres psql -U readpath -d readpath_lab
```

HTTP smoke validation passed before the measured run:

| Scenario | HTTP status | page.limit | page.offset | returnedCount | items length |
|---|---:|---:|---:|---:|---:|
| B1 | 200 | 50 | 100 | 50 | 50 |
| B2 | 200 | 50 | 100 | 50 | 50 |
| B3 | 200 | 50 | 10000 | 50 | 50 |

Future DB tuned, Denormalized DB, and OpenSearch benchmark PRs must reuse this
`product-search-baseline-v1` `moderate_skew` workload or create a new scenario
set version.

## Metrics

The top-level benchmark table should use only:

- overall API p95 latency from `http_req_duration`
- throughput from `http_reqs`
- error rate from `http_req_failed`

Supporting metrics:

- failed checks
- HTTP status check results
- request duration distribution in k6 summary JSON
- optional scenario-level Trend metrics:
  - `b1_selective_option_filter_duration`
  - `b2_broad_active_option_filter_duration`
  - `b3_deep_offset_option_filter_duration`

No production SLO or production RPS target is defined in this PR. Thresholds are
limited to correctness checks.

## State Checks

Before official runs, verify:

- Docker Desktop memory is 4096 MiB.
- No experiment-only `idx_exp_%` indexes remain.
- The Spring Boot app is running with the intended table pair.
- No seed, migration, DDL, index creation, or index deletion jobs are running.
- The app is running through Gradle `bootRun`.
- The same app execution mode is used for future comparisons.
- Heavy background tasks are not running during measured runs.

Safe read-only index check:

```powershell
docker compose exec postgres psql -U readpath -d readpath_lab -tAc "SELECT schemaname || '.' || tablename || ':' || indexname FROM pg_indexes WHERE schemaname = 'public' AND indexname LIKE 'idx_exp_%' ORDER BY 1;"
```

Docker resource checks:

```powershell
Get-Content $env:APPDATA\Docker\settings.json -Raw | ConvertFrom-Json |
  Select-Object cpus,memoryMiB,swapMiB,diskSizeMiB

docker info --format "{{.NCPU}} CPUs, {{.MemTotal}} bytes"
```

## Start Dependencies

Start PostgreSQL:

```powershell
docker compose up -d
docker compose ps
```

The benchmark assumes the matching products and product_options profile tables
have already been seeded.

## Start the App

The API table pair is selected by application properties, not request
parameters. Start one app process for one profile at a time.

Uniform:

```powershell
.\gradlew.bat bootRun --args="--readpath.product-search.baseline.products-table=products_uniform --readpath.product-search.baseline.product-options-table=product_options_uniform"
```

Moderate skew:

```powershell
.\gradlew.bat bootRun --args="--readpath.product-search.baseline.products-table=products_moderate_skew --readpath.product-search.baseline.product-options-table=product_options_moderate_skew"
```

High skew:

```powershell
.\gradlew.bat bootRun --args="--readpath.product-search.baseline.products-table=products_high_skew --readpath.product-search.baseline.product-options-table=product_options_high_skew"
```

If the Gradle wrapper has trouble with a non-ASCII Windows user home path, use a
separate ASCII Gradle user home outside the repository:

```powershell
$env:GRADLE_USER_HOME = "C:\gradle-cache\readpath-lab"
```

## Run k6

Install k6 manually before running the benchmark. The runner does not install
k6.

Moderate skew:

```powershell
.\benchmark\k6\run-product-search-baseline.ps1 -Profile moderate_skew
```

Optional parameters:

```powershell
.\benchmark\k6\run-product-search-baseline.ps1 `
  -Profile moderate_skew `
  -BaseUrl http://localhost:8080 `
  -VUs 10 `
  -WarmupDuration 1m `
  -Duration 10m
```

The runner executes:

1. scenario smoke validation
2. warm-up run
3. measured run

Warm-up results are excluded from official results. The measured summary JSON is
the official artifact. If checks fail, the run fails clearly and any failed
summary is not treated as an official result.

DB tuned API runs use the same scenario constants and can be run directly:

```powershell
$env:PROFILE='moderate_skew'
$env:BASE_URL='http://localhost:8080'
$env:VUS='10'
$env:DURATION='10m'
$env:SMOKE_ONLY='false'
$env:SUMMARY_JSON='benchmark\k6\results\products_moderate_skew\product_search_db_tuned_products_moderate_skew_YYYYMMDD_HHMMSS_summary.json'
& 'C:\Program Files\k6\k6.exe' run benchmark\k6\product-search-db-tuned.js
```

Use a 1m warm-up before the measured DB tuned run and exclude the warm-up from
official results.

Denormalized DB API runs use the same scenario constants and can be run
directly:

```powershell
$env:PROFILE='moderate_skew'
$env:BASE_URL='http://localhost:8080'
$env:VUS='10'
$env:DURATION='10m'
$env:SMOKE_ONLY='false'
$env:SUMMARY_JSON='benchmark\k6\results\products_moderate_skew\product_search_denormalized_db_products_moderate_skew_YYYYMMDD_HHMMSS_summary.json'
& 'C:\Program Files\k6\k6.exe' run --quiet benchmark\k6\product-search-denormalized-db.js
```

Use one B1 HTTP smoke, k6 smoke, and a 1m warm-up before the measured
Denormalized DB API run. Exclude HTTP smoke, k6 smoke, and warm-up from
official results.

## Results

Measured results are saved under:

```text
benchmark/k6/results/products_<profile>/
```

Artifact names include profile and timestamp:

```text
product_search_baseline_products_moderate_skew_YYYYMMDD_HHMMSS_summary.json
product_search_baseline_products_moderate_skew_YYYYMMDD_HHMMSS_observations.md
product_search_db_tuned_products_moderate_skew_YYYYMMDD_HHMMSS_summary.json
product_search_db_tuned_products_moderate_skew_YYYYMMDD_HHMMSS_observations.md
product_search_denormalized_db_products_moderate_skew_YYYYMMDD_HHMMSS_summary.json
product_search_denormalized_db_products_moderate_skew_YYYYMMDD_HHMMSS_observations.md
```

Do not commit huge raw logs or terminal dumps. Do not compare results across
different scenario versions, Docker settings, app execution modes, or dataset
profiles.

Representative baseline result:

The previous 1-minute measured artifact
`product_search_baseline_products_moderate_skew_20260428_105518_summary.json`
produced only 47 requests. It is retained as an initial pilot/superseded local
measured run and is not the representative p95 artifact.

The 10-minute measured run below is the official representative Baseline API
artifact for `moderate_skew`.

| Profile | Scenario set | VUs | Duration | Warm-up | Total requests | p95 latency | Throughput | Error rate | Failed checks |
|---|---|---:|---|---|---:|---:|---:|---:|---:|
| `moderate_skew` | `product-search-baseline-v1` | 10 | 10m | 1m | 382 | 29611.602365 ms | 0.6262291702382904 req/s | 0 | 0 |

Scenario-level p95:

| Scenario | p95 latency |
|---|---:|
| `B1_selective_option_filter` | 17124.170814999994 ms |
| `B2_broad_active_option_filter` | 33409.19112499999 ms |
| `B3_deep_offset_option_filter` | 18519.306105 ms |

`B2_broad_active_option_filter` is intentionally broad and may influence mixed
p95. Use the scenario-level p95 values when interpreting the mixed result.

Official artifacts:

```text
benchmark/k6/results/products_moderate_skew/product_search_baseline_products_moderate_skew_20260428_115844_summary.json
benchmark/k6/results/products_moderate_skew/product_search_baseline_products_moderate_skew_20260428_115844_observations.md
```

## DB Tuned API Result

The DB tuned API benchmark below reuses the same
`product-search-baseline-v1` `moderate_skew` workload as the official Baseline
API artifact:

- Same B1/B2/B3 constants.
- Same B1/B2/B3 weights: 40/40/20.
- Same VUs: 10.
- Same warm-up duration: 1m.
- Same measured duration: 10m.
- Same local k6 execution mode.
- Same Spring application table pair:
  `products_moderate_skew`, `product_options_moderate_skew`.

The DB tuned API uses PostgreSQL-backed `EXISTS`-style option filtering and
removes `SELECT DISTINCT`/`Unique` work where `EXISTS` makes it unnecessary. It
still uses OFFSET pagination. This PR does not introduce keyset pagination,
Denormalized DB, OpenSearch, Redis/cache, read models, or outbox.

Selected supporting indexes were added only for the representative measured
profile tables:

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

B1/B3 price remains a residual filter by design. Price is not placed before
`review_count` in the selected B1/B3 products index because prior products
experiments showed that range columns before ordering columns can leave explicit
sort work. The product_options index is option-filter-first because the workload
includes B2 broad option filtering and the DB-only artifacts made that broad
case more defensible for this combined path.

No indexes were added for `products_uniform`, `products_high_skew`,
`product_options_uniform`, or `product_options_high_skew` in this PR.
`uniform` and `high_skew` are deferred and were not measured.

Official DB tuned artifacts:

```text
benchmark/k6/results/products_moderate_skew/product_search_db_tuned_products_moderate_skew_20260428_150401_summary.json
benchmark/k6/results/products_moderate_skew/product_search_db_tuned_products_moderate_skew_20260428_150401_observations.md
```

| Profile | Scenario set | Read path | VUs | Duration | Warm-up | Total requests | Mixed p95 | Throughput | Error rate | Failed checks |
|---|---|---|---:|---|---|---:|---:|---:|---:|---:|
| `moderate_skew` | `product-search-baseline-v1` | DB tuned API | 10 | 10m | 1m | 31126 | 370.313125 ms | 51.85398922328235 req/s | 0 | 0 |

Scenario-level p95:

| Scenario | DB tuned p95 latency |
|---|---:|
| `B1_selective_option_filter` | 386.7013 ms |
| `B2_broad_active_option_filter` | 33.930324999999996 ms |
| `B3_deep_offset_option_filter` | 394.51556999999997 ms |

## Denormalized DB API Result

The Denormalized DB API benchmark below reuses the same
`product-search-baseline-v1` `moderate_skew` workload as the official Baseline
API and DB tuned API artifacts:

- Same B1/B2/B3 constants.
- Same B1/B2/B3 weights: 40/40/20.
- Same deterministic sequence: `[B1, B1, B2, B2, B3]`.
- Same VUs: 10.
- Same warm-up duration: 1m.
- Same measured duration: 10m.
- Same local k6 execution mode.

The Denormalized DB API reads from the PostgreSQL
`product_search_documents_moderate_skew` read table and filters options through
`option_signatures`. It still uses OFFSET pagination. This result is not an
OpenSearch result and is not a production capacity claim.

Official Denormalized DB artifacts:

```text
benchmark/k6/results/products_moderate_skew/product_search_denormalized_db_products_moderate_skew_20260430_102433_summary.json
benchmark/k6/results/products_moderate_skew/product_search_denormalized_db_products_moderate_skew_20260430_102433_observations.md
```

| Profile | Scenario set | Read path | VUs | Duration | Warm-up | Total requests | Mixed p95 | Throughput | Error rate | Failed checks |
|---|---|---|---:|---|---|---:|---:|---:|---:|---:|
| `moderate_skew` | `product-search-baseline-v1` | Denormalized DB API | 10 | 10m | 1m | 165685 | 127.34185999999998 ms | 276.1365354515421 req/s | 0 | 0 |

Scenario-level p95:

| Scenario | Denormalized DB p95 latency |
|---|---:|
| `B1_selective_option_filter` | 20.867624999999993 ms |
| `B2_broad_active_option_filter` | 23.145569999999992 ms |
| `B3_deep_offset_option_filter` | 152.9373 ms |

API p95 must not be compared with PostgreSQL `EXPLAIN` Execution Time.
OpenSearch comparison remains a later stage.

## Baseline vs DB Tuned vs Denormalized DB

Comparison uses only the official 10-minute Baseline API artifact:

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

`B2_broad_active_option_filter` is intentionally broad and may influence mixed
p95. Use scenario-level p95 values when interpreting the mixed result.

These are local synthetic benchmark results, not production capacity claims.
API p95 must not be compared with PostgreSQL `EXPLAIN` Execution Time.
OpenSearch comparison remains a later stage.
