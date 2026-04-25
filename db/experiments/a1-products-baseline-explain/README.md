# A-1a Products-Only Baseline EXPLAIN

## Purpose

This experiment captures reproducible PostgreSQL execution plans for representative products-only search, sort, and OFFSET pagination queries before index tuning.

These results are pre-index-tuning baseline execution plans.

The goal is to create evidence that later PRs can compare against failed single-column index attempts, composite indexes, partial indexes, keyset pagination, API/k6 baselines, and eventually a DB-backed API vs OpenSearch-backed API comparison.

## Why Products-Only Comes First

Products-only baseline plans isolate the core read path over the product listing table before adding join pressure from `product_options`.

This keeps the first baseline understandable:

- filter selectivity comes from product columns only
- sort cost comes from product columns only
- OFFSET pagination cost is visible without join fan-out
- later `product_options` JOIN experiments can be compared as an additional cost layer

## What This Measures

This experiment measures PostgreSQL execution plans for six products-only query cases using:

```sql
EXPLAIN (ANALYZE, BUFFERS, VERBOSE)
```

The query cases cover:

- category, status, price filters with `created_at DESC, id DESC`
- category, brand, status, price filters with `price ASC, id ASC`
- category and status filters with `review_count DESC, id DESC`
- shallow OFFSET pagination
- deep OFFSET pagination
- broad status-only and price-range browsing shapes

## What This Does Not Measure

This PR does not measure API p95 latency. API/k6 baseline will be added in a later PR after the products search API exists.

This experiment does not measure:

- user-facing API latency
- k6 load-test results
- OpenSearch behavior
- Redis behavior
- read model behavior
- product option JOIN behavior
- performance improvement

Do not compare PostgreSQL EXPLAIN query time directly with future OpenSearch API p95. Future OpenSearch comparison must be API-to-API using the same query cases.

## Dataset Caveat

These profiles are synthetic benchmark profiles and must not be described as production-derived.

The official seed profiles are:

- `products_uniform`
- `products_moderate_skew`
- `products_high_skew`

Each profile is intended to contain 10,000,000 rows after a full seed. The selected query parameters are synthetic/local benchmark parameters chosen from the deterministic seed logic and distribution verification artifacts under `db/seed/results`.

## Local Docker/PostgreSQL Caveat

Results produced by this experiment are local Docker/PostgreSQL artifacts. They are useful for comparing changes within the same local benchmark environment, but they are not production latency claims.

Record the environment, PostgreSQL version, and whether all three 10M profile tables were present when saving results.

## Query Cases

See [query-cases.md](query-cases.md) for the stable workload contract.

Case IDs:

- `Q1_category_status_price_created_at_shallow`
- `Q2_category_brand_status_price_price_asc_shallow`
- `Q3_category_status_review_count_shallow`
- `Q4_category_status_price_created_at_deep_offset`
- `Q5_status_only_created_at_shallow`
- `Q6_price_range_price_asc_shallow`

## Related Notes

- [observations.md](observations.md) records artifact-based observations from committed EXPLAIN result files.
- [A-1a Korean learning note](../../../docs/learning/project-a/a1/a1a-products-baseline-explain.md) explains the baseline learning goals and EXPLAIN reading points.

## How To Run Manually

Start PostgreSQL:

```powershell
docker compose up -d
```

Confirm the profile tables exist and contain the expected seeded rows:

```powershell
docker compose exec postgres psql -U readpath -d readpath_lab -c "SELECT 'products_uniform' AS table_name, COUNT(*) FROM products_uniform UNION ALL SELECT 'products_moderate_skew', COUNT(*) FROM products_moderate_skew UNION ALL SELECT 'products_high_skew', COUNT(*) FROM products_high_skew;"
```

Run the SQL for one profile from the repository root:

```powershell
Get-Content -Raw db/experiments/a1-products-baseline-explain/products_baseline_explain.sql |
  docker compose exec -T postgres psql -U readpath -d readpath_lab -v target_table=products_moderate_skew
```

Run all three profiles:

```powershell
Get-Content -Raw db/experiments/a1-products-baseline-explain/products_baseline_explain.sql |
  docker compose exec -T postgres psql -U readpath -d readpath_lab -v target_table=products_uniform

Get-Content -Raw db/experiments/a1-products-baseline-explain/products_baseline_explain.sql |
  docker compose exec -T postgres psql -U readpath -d readpath_lab -v target_table=products_moderate_skew

Get-Content -Raw db/experiments/a1-products-baseline-explain/products_baseline_explain.sql |
  docker compose exec -T postgres psql -U readpath -d readpath_lab -v target_table=products_high_skew
```

## How To Save EXPLAIN Outputs

Create the result directory if needed:

```powershell
New-Item -ItemType Directory -Force -Path db/experiments/a1-products-baseline-explain/results/products_moderate_skew
```

Save one profile:

```powershell
Get-Content -Raw db/experiments/a1-products-baseline-explain/products_baseline_explain.sql |
  docker compose exec -T postgres psql -U readpath -d readpath_lab -v target_table=products_moderate_skew |
  Tee-Object -FilePath db/experiments/a1-products-baseline-explain/results/products_moderate_skew/products_moderate_skew_baseline_explain_YYYYMMDD_HHMMSS.txt
```

Optional helper script:

```powershell
.\db\experiments\a1-products-baseline-explain\run-products-baseline-explain.ps1 -Profile all
```

## Expected Artifact Naming

Store actual EXPLAIN outputs under:

```text
db/experiments/a1-products-baseline-explain/results/<profile>/
```

Use this filename pattern:

```text
<profile>_baseline_explain_<YYYYMMDD_HHMMSS>.txt
```

Examples:

- `products_uniform_baseline_explain_20260425_132000.txt`
- `products_moderate_skew_baseline_explain_20260425_132000.txt`
- `products_high_skew_baseline_explain_20260425_132000.txt`

Do not commit result files unless the SQL was actually executed successfully against the matching seeded profile table.

## Later Use

Later PRs should reuse the same case IDs and query shapes to compare:

- failed single-column index attempts
- composite indexes
- partial indexes
- keyset pagination
- API/k6 p95 baseline and after-tuning comparison
- DB-backed API vs OpenSearch-backed API comparison

The later OpenSearch comparison must reuse the same query cases conceptually, but it must be measured API-to-API after both APIs exist.

## Next PR Recommendation

The next PR should keep PostgreSQL as the focus and run the same query cases against a narrowly scoped failed single-column index attempt, documenting why that index does or does not help the read path.
