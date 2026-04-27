# A-1a Products Single-Column Index Attempts

## Purpose

This experiment tests single-column index attempts against the existing products-only Q1-Q6 workload.

These single-column indexes are experiment attempts, not accepted production indexes.

This PR does not add permanent migrations.

The goal is to record where single-column indexes are chosen by the PostgreSQL planner, where they are ignored, where sort behavior remains, and why single-column indexes are not enough evidence for the full multi-condition products search workload.

## Why This Comes After Baseline EXPLAIN

The previous baseline experiment captured pre-index-tuning execution plans for Q1-Q6 under:

```text
db/experiments/a1-products-baseline-explain/
```

This experiment reuses the same query shapes and synthetic/local benchmark parameters so single-column index attempts can be compared against the baseline artifacts.

## What This Measures

For each target profile table, this experiment tests one single-column index at a time:

- `status`
- `price`
- `created_at`
- `review_count`

For each index attempt, the script runs:

```sql
EXPLAIN (ANALYZE, BUFFERS, VERBOSE)
```

against Q1-Q6 and records:

- scan/access pattern
- whether the planner chooses the experiment index
- sort behavior
- buffers
- rows removed by filter
- planning time
- execution time

## What This Does Not Measure

This experiment does not measure API p95 latency, k6 behavior, OpenSearch behavior, Redis behavior, read model behavior, product option JOIN behavior, or production latency.

Do not interpret a single query improvement as proof that the index solves the full products search workload.

Composite indexes, partial indexes, and keyset pagination are intentionally left for later PRs.

## Synthetic/Local Benchmark Caveat

The profile tables are synthetic benchmark profiles:

- `products_uniform`
- `products_moderate_skew`
- `products_high_skew`

These profiles must not be described as production-derived. Results from local Docker/PostgreSQL are local experiment artifacts, not production performance claims.

## Experiment Index Caveat

The SQL creates normal local experiment indexes, not `CREATE INDEX CONCURRENTLY`. Normal `CREATE INDEX` is acceptable here because this is a local reproducible experiment script, not an online production migration.

The script creates only one experiment index at a time, runs Q1-Q6, then drops that index before the next attempt. If the script is interrupted, use the cleanup commands below.

## How To Run One Profile

Start PostgreSQL:

```powershell
docker compose up -d
```

Run the default profile, `products_moderate_skew`:

```powershell
.\db\experiments\a1-products-single-column-index-attempts\run-products-single-column-index-attempts.ps1
```

Run a specific profile:

```powershell
.\db\experiments\a1-products-single-column-index-attempts\run-products-single-column-index-attempts.ps1 -Profile products_uniform
```

## How To Run All Profiles

```powershell
.\db\experiments\a1-products-single-column-index-attempts\run-products-single-column-index-attempts.ps1 -Profile all
```

Running all profiles creates and drops four indexes per 10M-row table. It can take time and disk I/O.

## Manual Command

```powershell
Get-Content -Raw db/experiments/a1-products-single-column-index-attempts/products_single_column_index_attempts.sql |
  docker compose exec -T postgres psql -U readpath -d readpath_lab -v target_table=products_moderate_skew
```

## How To Save Outputs

The helper script writes outputs under:

```text
db/experiments/a1-products-single-column-index-attempts/results/<profile>/
```

## Expected Artifact Naming

```text
<profile>_single_column_index_attempts_<YYYYMMDD_HHMMSS>.txt
```

Examples:

- `products_uniform_single_column_index_attempts_20260427_093000.txt`
- `products_moderate_skew_single_column_index_attempts_20260427_093000.txt`
- `products_high_skew_single_column_index_attempts_20260427_093000.txt`

Do not commit result files unless the experiment actually ran successfully against the matching seeded profile table.

## Cleanup Leftover Experiment Indexes

If a script is interrupted, clean up experiment indexes manually:

```powershell
docker compose exec postgres psql -U readpath -d readpath_lab -c "DROP INDEX IF EXISTS idx_exp_products_uniform_status, idx_exp_products_uniform_price, idx_exp_products_uniform_created_at, idx_exp_products_uniform_review_count;"
docker compose exec postgres psql -U readpath -d readpath_lab -c "DROP INDEX IF EXISTS idx_exp_products_moderate_skew_status, idx_exp_products_moderate_skew_price, idx_exp_products_moderate_skew_created_at, idx_exp_products_moderate_skew_review_count;"
docker compose exec postgres psql -U readpath -d readpath_lab -c "DROP INDEX IF EXISTS idx_exp_products_high_skew_status, idx_exp_products_high_skew_price, idx_exp_products_high_skew_created_at, idx_exp_products_high_skew_review_count;"
```

Verify cleanup:

```powershell
docker compose exec postgres psql -U readpath -d readpath_lab -c "SELECT tablename, indexname FROM pg_indexes WHERE schemaname = 'public' AND indexname LIKE 'idx_exp_%' ORDER BY tablename, indexname;"
```

## How This Will Be Used Next

The next PR should compare composite index candidates against the same Q1-Q6 workload. The purpose is to check whether indexes that align filter columns and sort columns explain the core products search workload better than isolated single-column attempts.

## Next PR Recommendation

Run a composite index comparison PR next. Keep partial indexes, keyset pagination, API/k6, and OpenSearch for later stages.
