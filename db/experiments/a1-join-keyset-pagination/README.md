# A-1c JOIN/EXISTS Keyset Pagination Comparison

## Purpose

This experiment compares deep `OFFSET` pagination with keyset pagination for products search queries that include `product_options` option filters through an `EXISTS` predicate.

This is a local PostgreSQL `EXPLAIN ANALYZE` artifact experiment. It does not add API code, k6, OpenSearch, Redis, read models, outbox, dashboards, or production migrations.

## Why This Comes After JOIN + DISTINCT vs EXISTS

`product_options` creates a 1:N relationship with products. The earlier JOIN baseline used `JOIN + DISTINCT`, which made row multiplication and duplicate removal visible in the plan. The previous EXISTS rewrite narrowed the query shape by asking only whether a matching option row exists.

This experiment tests pagination only after that narrower EXISTS shape is available. Testing keyset on top of the naive `JOIN + DISTINCT` shape would mix two questions: duplicate-removal work and skipped-page work.

## Query Shapes

All measured queries use:

```sql
EXISTS (
    SELECT 1
    FROM product_options_<profile> po
    WHERE po.product_id = p.id
      AND po.color = ...
      AND po.size = ...
      AND po.stock_status = ...
)
```

The pagination comparison keeps the same filter and ordering inside each case:

```sql
ORDER BY p.created_at DESC, p.id DESC
LIMIT 50 OFFSET ...
```

versus:

```sql
AND (p.created_at, p.id) < (:cursor_created_at, :cursor_id)
ORDER BY p.created_at DESC, p.id DESC
LIMIT 50
```

The cursor is the last row before the target page, derived with `OFFSET 99 LIMIT 1` for `OFFSET 100` cases and `OFFSET 9999 LIMIT 1` for the deep `OFFSET 10000` case. Cursor derivation is experiment setup only and is not part of the keyset read path.

## Cases

| case | shape |
|---|---|
| K1 | relatively selective category/status/price + less-common option filters, `LIMIT 50 OFFSET 100` |
| K2 | broader active listing + common option filters, `LIMIT 50 OFFSET 100` |
| K3 | broader active listing + common option filters, `LIMIT 50 OFFSET 10000` |

## Profiles

The supported matched synthetic profile pairs are:

| products table | product_options table |
|---|---|
| `products_uniform` | `product_options_uniform` |
| `products_moderate_skew` | `product_options_moderate_skew` |
| `products_high_skew` | `product_options_high_skew` |

Cross-profile combinations are intentionally rejected.

## Reused Option Index Families

The experiment reuses the two representative product_options index families from the EXISTS comparison:

| index family | columns |
|---|---|
| option-filter-first | `(color, size, stock_status, product_id)` |
| join-key-first | `(product_id, color, size, stock_status)` |

It also creates one experiment-only products-side ordering index:

```sql
(created_at DESC, id DESC) WHERE status = 'ACTIVE'
```

That index keeps the pagination read shape observable. It is not a production index recommendation and is dropped after each run.

## Result Equivalence

The SQL verifies that each keyset query returns the same logical next page as the corresponding OFFSET query for the derived cursor boundary.

If any page ID sequence differs, the script raises an exception and the run fails.

## What To Observe

Focus on:

- plan shape
- rows processed and rows removed by filter
- buffers
- sort behavior
- whether temp I/O appears
- whether OFFSET advances extra rows before returning the page
- whether keyset reduces skipped-row work
- whether EXISTS keeps plans free from visible `Unique`/DISTINCT nodes

`EXPLAIN` Execution Time is only a local DB artifact. Do not describe it as API p95 latency.

## What This Does Not Prove

This experiment does not prove production performance, API latency, final index adoption, OpenSearch direction, Redis/read-model direction, or user-facing pagination semantics.

It does not benchmark application code, network overhead, JSON serialization, connection pools, k6 traffic, cold cache behavior, or production data.

## How To Run One Profile

Start PostgreSQL:

```powershell
docker compose up -d
```

Run the default profile, `products_moderate_skew`:

```powershell
.\db\experiments\a1-join-keyset-pagination\run-join-keyset-pagination.ps1
```

Run a specific profile:

```powershell
.\db\experiments\a1-join-keyset-pagination\run-join-keyset-pagination.ps1 -Profile products_uniform
```

## How To Run All Profiles

```powershell
.\db\experiments\a1-join-keyset-pagination\run-join-keyset-pagination.ps1 -Profile all
```

## Manual psql Command

```powershell
Get-Content -Raw db/experiments/a1-join-keyset-pagination/join_keyset_pagination.sql |
  docker compose exec -T postgres psql -U readpath -d readpath_lab -v products_table=products_moderate_skew -v product_options_table=product_options_moderate_skew
```

## Expected Artifacts

The PowerShell helper saves outputs under:

```text
db/experiments/a1-join-keyset-pagination/results/<profile>/
```

Expected filename format:

```text
<profile>_join_keyset_pagination_<YYYYMMDD_HHMMSS>.txt
```

## Cleanup Leftover Experiment Indexes

If a script is interrupted, clean up experiment indexes manually:

```powershell
docker compose exec postgres psql -U readpath -d readpath_lab -c "DROP INDEX IF EXISTS idx_exp_products_uniform_jk_active_created, idx_exp_po_uniform_jk_opt_first, idx_exp_po_uniform_jk_join_first;"
docker compose exec postgres psql -U readpath -d readpath_lab -c "DROP INDEX IF EXISTS idx_exp_products_moderate_skew_jk_active_created, idx_exp_po_moderate_skew_jk_opt_first, idx_exp_po_moderate_skew_jk_join_first;"
docker compose exec postgres psql -U readpath -d readpath_lab -c "DROP INDEX IF EXISTS idx_exp_products_high_skew_jk_active_created, idx_exp_po_high_skew_jk_opt_first, idx_exp_po_high_skew_jk_join_first;"
```

Verify cleanup:

```powershell
docker compose exec postgres psql -U readpath -d readpath_lab -c "SELECT tablename, indexname FROM pg_indexes WHERE schemaname = 'public' AND indexname LIKE 'idx_exp_%' ORDER BY tablename, indexname;"
```

The expected cleanup result is zero rows.
