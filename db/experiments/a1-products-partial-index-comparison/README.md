# A-1a Products Partial Index Comparison

## Purpose

This experiment compares partial index candidates against the existing products-only Q1-Q6 workload.

These partial indexes are experiment candidates, not accepted production indexes.

This PR does not add permanent migrations.

The goal is to observe whether PostgreSQL chooses partial indexes with `WHERE status = 'ACTIVE'`, and how those candidates affect scan/access pattern, sort behavior, buffers, rows removed by filter, planning time, and execution time.

## Why This Comes After Composite Index Comparison

The previous composite index comparison tested full composite index candidates against the same Q1-Q6 workload.

This experiment keeps the same query cases, but moves the repeated `status = 'ACTIVE'` predicate into partial index predicates for Q1-Q5 where applicable. Q6 remains a control case because it has no `status` predicate.

## What Partial Indexes Are

A partial index indexes only rows that satisfy a predicate. In this experiment, every candidate uses:

```sql
WHERE status = 'ACTIVE'
```

The tested candidates are local experiment indexes only. They are not production indexes and are not added through schema migrations.

## What This Measures

For each partial index candidate, the experiment runs:

- Q1 category/status/price/latest shallow OFFSET
- Q2 category/brand/status/price/price ASC shallow OFFSET
- Q3 category/status/review_count shallow OFFSET
- Q4 category/status/price/latest deep OFFSET
- Q5 status-only/latest shallow OFFSET
- Q6 price-only/price ASC shallow OFFSET control case

The output records:

- whether PostgreSQL chooses the partial index
- scan/access pattern
- sort behavior
- buffers
- rows removed by filter
- planning time
- execution time

## What This Does Not Measure

This experiment does not measure API p95 latency, k6 behavior, OpenSearch behavior, Redis behavior, read model behavior, product option JOIN behavior, or production latency.

Do not interpret one query improvement as proof that the partial index solves the full products search workload.

Keyset pagination, product_options JOIN, API/k6, and OpenSearch are intentionally left for later PRs.

## Synthetic/Local Benchmark Caveat

The profile tables are synthetic benchmark profiles:

- `products_uniform`
- `products_moderate_skew`
- `products_high_skew`

These profiles must not be described as production-derived. Results from local Docker/PostgreSQL are local experiment artifacts, not production performance claims.

## Experiment Index Caveat

The SQL creates normal local experiment indexes, not `CREATE INDEX CONCURRENTLY`. Normal `CREATE INDEX` is acceptable here because this is a local reproducible experiment script, not an online production migration.

The script creates only one experiment partial index at a time, runs Q1-Q6, then drops that index before the next candidate. If the script is interrupted, use the cleanup commands below.

## Partial Index Candidates

| candidate | index columns | predicate | primary target | reason |
|---|---|---|---|---|
| active category/latest | `category_id, created_at DESC, id DESC` | `status = 'ACTIVE'` | Q1, Q4 | Supports category filtering and latest ordering for active products, leaving price as a residual filter. |
| active category/price/latest | `category_id, price, created_at DESC, id DESC` | `status = 'ACTIVE'` | Q1, Q4 | Checks whether including price range changes scan/filter behavior. A range column before `created_at` may limit how much the index can satisfy `ORDER BY created_at`. |
| active category/brand/price | `category_id, brand_id, price ASC, id ASC` | `status = 'ACTIVE'` | Q2 | Aligns category/brand equality filters with price ordering for active products. |
| active category/review_count | `category_id, review_count DESC, id DESC` | `status = 'ACTIVE'` | Q3 | Aligns category filtering with review-count ordering for active products. |
| active latest | `created_at DESC, id DESC` | `status = 'ACTIVE'` | Q5 | Aligns the broad status-only latest listing query with an active-only latest index. |

## Why Q6 Is A Control Case

Q6 filters only by `price BETWEEN 10000 AND 100000` and orders by `price ASC, id ASC`.

Q6 has no `status = 'ACTIVE'` predicate, so the active-only partial indexes should not be expected to help Q6. Keeping Q6 in the workload helps confirm whether predicate matching affects planner index choice.

## How To Run One Profile

Start PostgreSQL:

```powershell
docker compose up -d
```

Run the default profile, `products_moderate_skew`:

```powershell
.\db\experiments\a1-products-partial-index-comparison\run-products-partial-index-comparison.ps1
```

Run a specific profile:

```powershell
.\db\experiments\a1-products-partial-index-comparison\run-products-partial-index-comparison.ps1 -Profile products_uniform
```

## How To Run All Profiles

```powershell
.\db\experiments\a1-products-partial-index-comparison\run-products-partial-index-comparison.ps1 -Profile all
```

## Manual Command

```powershell
Get-Content -Raw db/experiments/a1-products-partial-index-comparison/products_partial_index_comparison.sql |
  docker compose exec -T postgres psql -U readpath -d readpath_lab -v target_table=products_moderate_skew
```

## How To Save Outputs

The PowerShell helper saves outputs under:

```text
db/experiments/a1-products-partial-index-comparison/results/<profile>/
```

## Expected Artifact Naming

```text
<profile>_partial_index_comparison_<YYYYMMDD_HHMMSS>.txt
```

Examples:

- `products_uniform_partial_index_comparison_20260427_120000.txt`
- `products_moderate_skew_partial_index_comparison_20260427_120000.txt`
- `products_high_skew_partial_index_comparison_20260427_120000.txt`

## Cleanup Leftover Experiment Indexes

If a script is interrupted, clean up experiment indexes manually:

```powershell
docker compose exec postgres psql -U readpath -d readpath_lab -c "DROP INDEX IF EXISTS idx_exp_products_uniform_active_cat_created_id, idx_exp_products_uniform_active_cat_price_created_id, idx_exp_products_uniform_active_cat_brand_price_id, idx_exp_products_uniform_active_cat_review_id, idx_exp_products_uniform_active_created_id;"
docker compose exec postgres psql -U readpath -d readpath_lab -c "DROP INDEX IF EXISTS idx_exp_products_moderate_skew_active_cat_created_id, idx_exp_products_moderate_skew_active_cat_price_created_id, idx_exp_products_moderate_skew_active_cat_brand_price_id, idx_exp_products_moderate_skew_active_cat_review_id, idx_exp_products_moderate_skew_active_created_id;"
docker compose exec postgres psql -U readpath -d readpath_lab -c "DROP INDEX IF EXISTS idx_exp_products_high_skew_active_cat_created_id, idx_exp_products_high_skew_active_cat_price_created_id, idx_exp_products_high_skew_active_cat_brand_price_id, idx_exp_products_high_skew_active_cat_review_id, idx_exp_products_high_skew_active_created_id;"
```

Verify cleanup:

```powershell
docker compose exec postgres psql -U readpath -d readpath_lab -c "SELECT tablename, indexname FROM pg_indexes WHERE schemaname = 'public' AND indexname LIKE 'idx_exp_%' ORDER BY tablename, indexname;"
```

The expected cleanup result is zero rows.

## How This Will Be Used Next

Later PRs can compare these partial-index artifacts with baseline, single-column, and full composite index artifacts using the same Q1-Q6 workload.

## Next PR Recommendation

The next PR should discuss or test keyset pagination for the deep OFFSET case, especially Q4. Keep product_options JOIN, API/k6, and OpenSearch for later stages.
