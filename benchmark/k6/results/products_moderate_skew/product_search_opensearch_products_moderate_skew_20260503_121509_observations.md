# Product Search OpenSearch API k6 Observation

## Run Identity

| Item | Value |
|---|---|
| Status | official primary OpenSearch local synthetic result |
| Scenario set | product-search-baseline-v1 |
| Workload version | product-search-baseline-v1 |
| Profile | moderate_skew |
| Read path flag state | readpath.product-search.read-path=opensearch |
| Endpoint | GET /api/v1/products/search |
| OpenSearch URL | http://localhost:9200 |
| OpenSearch read alias | products_search_read |
| OpenSearch expected index | products_search_benchmark_moderate_skew_v1 |
| OpenSearch max_result_window | 10050 |
| OpenSearch timeout | 5000 ms |
| Circuit breaker enabled | true |
| Circuit breaker threshold | 3 |
| Circuit breaker open wait | 1000 ms |
| Circuit breaker half-open permitted calls | 1 |
| App execution mode | Gradle bootRun |
| k6 execution mode | local k6 |
| VUs | 10 |
| Warm-up duration | 1m |
| Measured duration | 10m |
| Timestamp | 20260503_121509 |
| Docker memory setting | 4096 MiB |
| Official summary JSON | C:\projects\readpath-lab\readpath-lab\benchmark\k6\results\products_moderate_skew\product_search_opensearch_products_moderate_skew_20260503_121509_summary.json |

This is a local synthetic moderate_skew benchmark result, not a production
capacity claim. It does not define production readiness, capacity, SLA, or SLO.

## Environment / Control Checks

- PostgreSQL container: readpath-postgres, healthy before measured run.
- OpenSearch health: green/yellow check passed before measured run.
- Dataset profile: products_moderate_skew.
- Scenario version: product-search-baseline-v1.
- OpenSearch alias points to expected full-corpus benchmark index: products_search_benchmark_moderate_skew_v1.
- OpenSearch options mapping type: nested.
- Indexed root document count: 10000000.
- No seed, migration, index creation, backfill, catch-up replay, or relay process was intentionally started by this benchmark runner.
- The measured app process was freshly started before the measured run, so fallback/circuit-breaker counters began from process-local zero.
- Circuit breaker was expected to start closed in the fresh measured app process.

## OpenSearch Alias Readiness

- Full corpus preparation artifact:
  `benchmark/k6/results/products_moderate_skew/opensearch_index_prepare_20260503_121439/`
- Physical index: `products_search_benchmark_moderate_skew_v1`
- Official aliases: `products_search_read`, `products_search_write`,
  `products_search_current`
- Source products: 10000000
- Source options: 20500029
- Root document count validation: 10000000 / 10000000, pass
- Status count validation: ACTIVE 9000000, DELETED 300000, SOLD_OUT 700000,
  pass
- Mapping validation: `options.type=nested`, pass
- Index setting validation: `index.max_result_window=10050`, pass
- B1_selective_option_filter: matching_count=13380, required_min_count=150, passes=True
- B2_broad_active_option_filter: matching_count=720000, required_min_count=150, passes=True
- B3_deep_offset_option_filter: matching_count=13380, required_min_count=10050, passes=True

## Scenario Constants

| Scenario | Weight | Parameters |
|---|---:|---|
| B1_selective_option_filter | 40% | categoryId=75, brandId=943, status=ACTIVE, minPrice=10000, maxPrice=100000, color=BLACK, size=M, stockStatus=IN_STOCK, sort=reviewCountDesc, limit=50, offset=100 |
| B2_broad_active_option_filter | 40% | status=ACTIVE, color=BLACK, size=M, stockStatus=IN_STOCK, sort=createdAtDesc, limit=50, offset=100 |
| B3_deep_offset_option_filter | 20% | categoryId=75, brandId=943, status=ACTIVE, minPrice=10000, maxPrice=100000, color=BLACK, size=M, stockStatus=IN_STOCK, sort=reviewCountDesc, limit=50, offset=10000 |

## Commands

~~~powershell
.\benchmark\k6\run-product-search-opensearch.ps1 -Profile moderate_skew -OpenSearchUrl http://localhost:9200 -OpenSearchAlias products_search_read -VUs 10 -WarmupDuration 1m -Duration 10m -TimeoutMs 5000 -AppReadyTimeoutSeconds 300
~~~

The runner executed HTTP smoke, k6 smoke, warm-up, then measured run. HTTP
smoke, k6 smoke, and warm-up are not official benchmark artifacts.

## HTTP Smoke

| Scenario | HTTP status | items length | page.limit | page.offset | returnedCount | Result |
|---|---:|---:|---:|---:|---:|---|
| B1_selective_option_filter | 200 | 50 | 50 | 100 | 50 | pass |
| B2_broad_active_option_filter | 200 | 50 | 50 | 100 | 50 | pass |
| B3_deep_offset_option_filter | 200 | 50 | 50 | 10000 | 50 | pass |

## k6 Smoke

Result: pass, exit code 0, failed checks 0. k6 smoke is not an official result.

## Warm-up

Result: pass, exit code 0. Warm-up is excluded from official results.

## Measured Run

| Metric | Value |
|---|---:|
| Mixed p95 | 98.89618499999996 ms |
| B1 p95 | 86.04545999999996 ms |
| B2 p95 | 70.34295999999999 ms |
| B3 p95 | 125.53488499999999 ms |
| Throughput | 176.2846593857517 req/s |
| Error rate | 0 |
| Failed checks | 0 |
| Total requests | 105780 |
| Fallback count | 0 |
| Fallback success count | 0 |
| Timeout count | 0 |
| Circuit breaker open count | 0 |
| Short-circuited request count | 0 |

Primary official OpenSearch result: yes. The measured run had failed checks 0,
error rate 0, fallback count 0, fallback success count 0, timeout count 0,
circuit breaker open count 0, and short-circuited request count 0.

## Scenario Iteration Counts

| Scenario | Iterations |
|---|---:|
| B1 | 42317 |
| B2 | 42309 |
| B3 | 21154 |

## Comparison Table

Comparison uses existing official local synthetic artifacts when present.

| Read path | Total requests | Mixed p95 | B1 p95 | B2 p95 | B3 p95 | Throughput | Error rate | Failed checks |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| Baseline API | 382 | 29611.602365 ms | 17124.170814999994 ms | 33409.19112499999 ms | 18519.306105 ms | 0.6262291702382904 req/s | 0 | 0 |
| DB tuned API | 31126 | 370.313125 ms | 386.7013 ms | 33.930324999999996 ms | 394.51556999999997 ms | 51.85398922328235 req/s | 0 | 0 |
| Denormalized DB API | 165685 | 127.34185999999998 ms | 20.867624999999993 ms | 23.145569999999992 ms | 152.9373 ms | 276.1365354515421 req/s | 0 | 0 |
| OpenSearch API | 105780 | 98.89618499999996 ms | 86.04545999999996 ms | 70.34295999999999 ms | 125.53488499999999 ms | 176.2846593857517 req/s | 0 | 0 |

## Limitations

- Local workstation and Docker Desktop result only.
- No production capacity, readiness, SLA, or SLO claim.
- No relevance tuning, synonym search, typo tolerance, autocomplete, Kafka, Debezium, CDC pipeline, production monitoring, or dashboarding was added.
- API p95 must not be compared with PostgreSQL EXPLAIN Execution Time.
