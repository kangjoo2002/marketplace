# A-1a Products Keyset Pagination Comparison

## Purpose

This experiment compares Q4 deep OFFSET pagination with keyset pagination for the products-only workload.

This PR compares pagination query shapes; it does not implement an API.

The goal is to observe whether keyset pagination changes plan shape, rows processed, sort behavior, buffers, and `EXPLAIN` Execution Time compared with Q4 deep OFFSET under the same products-only filter and ordering shape.

## Why This PR Comes After Partial Index Comparison

The previous partial index comparison showed that the active category/latest partial index shape can support the Q4 ordering shape for some profiles, while Q4 deep OFFSET remained profile-dependent.

This experiment carries forward only that supporting index shape and narrows the question to pagination shape:

```sql
(category_id, created_at DESC, id DESC) WHERE status = 'ACTIVE'
```

It does not compare multiple index candidates.

## What Keyset Pagination Is

Keyset pagination uses the last row from the previous page as a cursor, then asks for rows after that cursor in the same deterministic ordering.

For this experiment, the ordering is:

```sql
ORDER BY created_at DESC, id DESC
```

The cursor predicate is:

```sql
(created_at, id) < (:cursor_created_at, :cursor_id)
```

## What Q4 Deep OFFSET Measures

Q4 uses the existing products-only query shape:

```sql
WHERE category_id = 35
  AND status = 'ACTIVE'
  AND price BETWEEN 10000 AND 100000
ORDER BY created_at DESC, id DESC
LIMIT 50 OFFSET 10000
```

This measures the local PostgreSQL plan and execution behavior for a deep OFFSET page under the synthetic profile table.

Do not interpret EXPLAIN Execution Time as API p95 latency.

## What The Keyset Query Changes

The keyset query keeps the same filters, ordering, and page size, but replaces deep OFFSET with a cursor boundary:

```sql
WHERE category_id = 35
  AND status = 'ACTIVE'
  AND price BETWEEN 10000 AND 100000
  AND (created_at, id) < (:cursor_created_at, :cursor_id)
ORDER BY created_at DESC, id DESC
LIMIT 50
```

To simulate the same page as `OFFSET 10000 LIMIT 50`, the cursor represents the last row before the target page. For `ORDER BY created_at DESC, id DESC`, the boundary cursor is derived with:

```sql
LIMIT 1 OFFSET 9999
```

## Cursor Derivation Caveat

The cursor derivation query is experiment setup only and must not be interpreted as keyset read-path latency.

The local SQL derives cursor values with an OFFSET query so the experiment is reproducible from only a profile table. A real keyset read path would receive cursor values from the previous page response rather than computing them with a deep OFFSET query.

## Supporting Experiment Index Caveat

The supporting index is an experiment index, not an accepted production index.

The SQL creates a normal local index:

```sql
CREATE INDEX idx_exp_<target_table>_keyset_active_cat_created_id
ON <target_table> (category_id, created_at DESC, id DESC)
WHERE status = 'ACTIVE';
```

Normal `CREATE INDEX` is acceptable for this local reproducible experiment because this is not an online production migration. The SQL drops the index after the experiment and verifies that no `idx_exp_%` indexes remain.

## What This Experiment Measures

This experiment records:

- plan/access pattern for Q4 deep OFFSET
- plan/access pattern for Q4 keyset pagination
- sort behavior
- rows processed and rows removed by filter when visible
- buffers
- planning time
- `EXPLAIN` Execution Time
- optional result-equivalence sanity check for page IDs

## What This Experiment Intentionally Does Not Measure

This experiment does not measure API p95 latency, application behavior, k6 behavior, production behavior, write overhead, index storage tradeoffs, or user-facing pagination semantics.

product_options JOIN, API/k6, OpenSearch, Redis, and read models are intentionally left for later PRs.

It does not add product_options, JOIN queries, API code, k6, OpenSearch, Redis, read models, outbox, monitoring, dashboards, permanent migrations, or production indexes.

## Synthetic/Local Benchmark Caveat

The profile tables are synthetic local benchmark profiles:

- `products_uniform`
- `products_moderate_skew`
- `products_high_skew`

These profiles must not be described as production-derived. Results from local Docker/PostgreSQL are local experiment artifacts, not production performance claims.

## How To Run One Profile

Start PostgreSQL:

```powershell
docker compose up -d
```

Run the default profile, `products_moderate_skew`:

```powershell
.\db\experiments\a1-products-keyset-pagination-comparison\run-products-keyset-pagination-comparison.ps1
```

Run a specific profile:

```powershell
.\db\experiments\a1-products-keyset-pagination-comparison\run-products-keyset-pagination-comparison.ps1 -Profile products_uniform
```

## How To Run All Profiles

```powershell
.\db\experiments\a1-products-keyset-pagination-comparison\run-products-keyset-pagination-comparison.ps1 -Profile all
```

## Manual Command

```powershell
Get-Content -Raw db/experiments/a1-products-keyset-pagination-comparison/products_keyset_pagination_comparison.sql |
  docker compose exec -T postgres psql -U readpath -d readpath_lab -v target_table=products_moderate_skew
```

## How To Save Outputs

The PowerShell helper saves outputs under:

```text
db/experiments/a1-products-keyset-pagination-comparison/results/<profile>/
```

## Expected Artifact Naming

```text
<profile>_keyset_pagination_comparison_<YYYYMMDD_HHMMSS>.txt
```

Examples:

- `products_uniform_keyset_pagination_comparison_20260427_120000.txt`
- `products_moderate_skew_keyset_pagination_comparison_20260427_120000.txt`
- `products_high_skew_keyset_pagination_comparison_20260427_120000.txt`

## Cleanup Leftover Experiment Indexes

If a script is interrupted, clean up experiment indexes manually:

```powershell
docker compose exec postgres psql -U readpath -d readpath_lab -c "DROP INDEX IF EXISTS idx_exp_products_uniform_keyset_active_cat_created_id;"
docker compose exec postgres psql -U readpath -d readpath_lab -c "DROP INDEX IF EXISTS idx_exp_products_moderate_skew_keyset_active_cat_created_id;"
docker compose exec postgres psql -U readpath -d readpath_lab -c "DROP INDEX IF EXISTS idx_exp_products_high_skew_keyset_active_cat_created_id;"
```

Verify cleanup:

```powershell
docker compose exec postgres psql -U readpath -d readpath_lab -c "SELECT tablename, indexname FROM pg_indexes WHERE schemaname = 'public' AND indexname LIKE 'idx_exp_%' ORDER BY tablename, indexname;"
```

The expected cleanup result is zero rows.

## How This Experiment Will Be Used Later

Later PRs can use these artifacts to decide whether the Q4 pagination shape should be mapped into a products search API design and compared under API-level tests after that API exists.

This experiment can also help decide what should be measured when product_options JOIN behavior is introduced later.

## Next PR Recommendation

The next PR should be either a product_options JOIN baseline for the products search read path or an API mapping discussion for OFFSET vs keyset semantics. It should not jump to OpenSearch from this stage.
