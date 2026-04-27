# A-1a Products Composite Index Comparison

## Purpose

This experiment compares composite index candidates against the existing products-only Q1-Q6 workload.

These composite indexes are experiment candidates, not accepted production indexes.

This PR does not add permanent migrations.

The goal is to learn which composite index candidates are selected by PostgreSQL and how they affect scan/access pattern, sort behavior, buffers, rows removed by filter, planning time, and EXPLAIN Execution Time.

## Why This Comes After Single-Column Index Attempts

The previous single-column experiment showed that isolated indexes such as `status`, `price`, `created_at`, and `review_count` only matched specific query shapes. The core products search workload combines equality filters, range filters, and ordering.

This experiment tests small composite candidates that align more closely with Q1-Q6 while still remaining experiment-only and local.

## What This Measures

For each profile table, the script creates one composite experiment index candidate at a time, runs Q1-Q6 with:

```sql
EXPLAIN (ANALYZE, BUFFERS, VERBOSE)
```

then drops that candidate before moving to the next one.

Measured observations include:

- whether the planner chooses the candidate
- scan/access pattern
- sort behavior
- buffers
- rows removed by filter
- planning time
- execution time

## What This Does Not Measure

This experiment does not measure API p95 latency, k6 behavior, OpenSearch behavior, Redis behavior, read model behavior, product option JOIN behavior, or production latency.

Do not interpret one query improvement as proof that the index solves the full products search workload.

Partial indexes, keyset pagination, product_options JOIN, API/k6, and OpenSearch are intentionally left for later PRs.

## Synthetic/Local Benchmark Caveat

The profile tables are synthetic benchmark profiles:

- `products_uniform`
- `products_moderate_skew`
- `products_high_skew`

These profiles must not be described as production-derived. Results from local Docker/PostgreSQL are local experiment artifacts, not production performance claims.

## Composite Index Candidates

| candidate | index columns | primary query focus | why it exists |
|---|---|---|---|
| category/status/latest | `category_id, status, created_at DESC, id DESC` | Q1, Q4 | Supports equality filters and latest ordering while leaving price range as a residual filter. |
| category/status/price/latest | `category_id, status, price, created_at DESC, id DESC` | Q1, Q4 | Checks whether including price range before latest ordering changes scan/filter behavior. A range column before sort columns may limit how much the index can satisfy `ORDER BY created_at DESC, id DESC`. |
| category/brand/status/price | `category_id, brand_id, status, price ASC, id ASC` | Q2 | Aligns Q2 equality filters with price ordering. |
| category/status/review_count | `category_id, status, review_count DESC, id DESC` | Q3 | Aligns Q3 equality filters with review-count ordering. |

No partial indexes, keyset-specific indexes, or product_options indexes are included in this PR.

## How To Run One Profile

Start PostgreSQL:

```powershell
docker compose up -d
```

Run the default profile, `products_moderate_skew`:

```powershell
.\db\experiments\a1-products-composite-index-comparison\run-products-composite-index-comparison.ps1
```

Run a specific profile:

```powershell
.\db\experiments\a1-products-composite-index-comparison\run-products-composite-index-comparison.ps1 -Profile products_uniform
```

## How To Run All Profiles

```powershell
.\db\experiments\a1-products-composite-index-comparison\run-products-composite-index-comparison.ps1 -Profile all
```

Running all profiles creates and drops four composite indexes per 10M-row table. It can take time and disk I/O.

## Manual Command

```powershell
Get-Content -Raw db/experiments/a1-products-composite-index-comparison/products_composite_index_comparison.sql |
  docker compose exec -T postgres psql -U readpath -d readpath_lab -v target_table=products_moderate_skew
```

## How To Save Outputs

The helper script writes outputs under:

```text
db/experiments/a1-products-composite-index-comparison/results/<profile>/
```

## Expected Artifact Naming

```text
<profile>_composite_index_comparison_<YYYYMMDD_HHMMSS>.txt
```

Examples:

- `products_uniform_composite_index_comparison_20260427_113000.txt`
- `products_moderate_skew_composite_index_comparison_20260427_113000.txt`
- `products_high_skew_composite_index_comparison_20260427_113000.txt`

Do not commit result files unless the experiment actually ran successfully against the matching seeded profile table.

## Cleanup Leftover Experiment Indexes

If a script is interrupted, clean up experiment indexes manually:

```powershell
docker compose exec postgres psql -U readpath -d readpath_lab -c "DROP INDEX IF EXISTS idx_exp_products_uniform_cat_status_created_id, idx_exp_products_uniform_cat_status_price_created_id, idx_exp_products_uniform_cat_brand_status_price_id, idx_exp_products_uniform_cat_status_review_id;"
docker compose exec postgres psql -U readpath -d readpath_lab -c "DROP INDEX IF EXISTS idx_exp_products_moderate_skew_cat_status_created_id, idx_exp_products_moderate_skew_cat_status_price_created_id, idx_exp_products_moderate_skew_cat_brand_status_price_id, idx_exp_products_moderate_skew_cat_status_review_id;"
docker compose exec postgres psql -U readpath -d readpath_lab -c "DROP INDEX IF EXISTS idx_exp_products_high_skew_cat_status_created_id, idx_exp_products_high_skew_cat_status_price_created_id, idx_exp_products_high_skew_cat_brand_status_price_id, idx_exp_products_high_skew_cat_status_review_id;"
```

Verify cleanup:

```powershell
docker compose exec postgres psql -U readpath -d readpath_lab -c "SELECT tablename, indexname FROM pg_indexes WHERE schemaname = 'public' AND indexname LIKE 'idx_exp_%' ORDER BY tablename, indexname;"
```

## How This Will Be Used Next

Later PRs can use these artifacts to decide which candidate should be compared with partial indexes and which query cases still need pagination changes.

## Next PR Recommendation

Run a partial index comparison for the most promising composite candidate, or run a focused keyset pagination experiment for Q4 if deep OFFSET remains expensive.
