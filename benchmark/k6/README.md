# Product Search k6 Baseline

This benchmark measures the product search API as a black-box HTTP endpoint. It
does not measure PostgreSQL `EXPLAIN` execution time and does not collect
internal application timers.

Target endpoint:

```http
GET /api/v1/products/search
```

Baseline query shape under the API:

```text
products + product_options
JOIN + DISTINCT
OFFSET pagination
```

This benchmark does not use or assume `EXISTS`, keyset pagination, OpenSearch,
Redis, caching, denormalized read tables, outbox, or `totalCount`.

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

## Results

Measured results are saved under:

```text
benchmark/k6/results/products_<profile>/
```

Artifact names include profile and timestamp:

```text
product_search_baseline_moderate_skew_YYYYMMDD_HHMMSS_summary.json
product_search_baseline_moderate_skew_YYYYMMDD_HHMMSS_observations.md
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

`uniform` and `high_skew` were not measured in this PR.
