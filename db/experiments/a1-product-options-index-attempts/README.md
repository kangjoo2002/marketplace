# A-1b Product Options Index Attempts

## Purpose

This experiment tests product_options-side index candidates against the existing products + product_options JOIN + DISTINCT baseline workload.

This PR tests experiment-only product_options index candidates. It does not add accepted production indexes.

The goal is to observe whether product_options indexes change access path, JOIN type, JOIN input size, DISTINCT/Unique behavior, sort behavior, buffers, rows removed by filter, and `EXPLAIN` Execution Time.

## Why This Comes After JOIN + DISTINCT Baseline EXPLAIN

The previous JOIN baseline PR established naive `SELECT DISTINCT p.*` behavior without product_options tuning indexes.

This PR keeps the same query shapes and option parameters, then adds one product_options experiment index candidate at a time. Each candidate is dropped before the next candidate is tested.

## What Product Options Index Attempts Measure

The experiment checks whether PostgreSQL changes:

- product_options access path
- JOIN type
- row counts flowing into JOIN
- duplicate removal through `Unique`
- sort method and temp I/O
- buffers
- rows removed by filter
- `EXPLAIN` Execution Time

## Reused J1-J6 Workload

The workload is reused from `db/experiments/a1-product-options-join-baseline-explain/`.

| case | shape |
|---|---|
| J1 | category/status/price/latest + option filters, `LIMIT 50 OFFSET 100` |
| J2 | category/brand/status/price/price ASC + option filters, `LIMIT 50 OFFSET 100` |
| J3 | category/status/review-count sort + option filters, `LIMIT 50 OFFSET 100` |
| J4 | category/status/price/latest + option filters, `LIMIT 50 OFFSET 10000` |
| J5 | broad active/latest listing + option filters, `LIMIT 50 OFFSET 100` |
| J6 | option selectivity control counts |

This PR keeps the naive JOIN + DISTINCT query shape. EXISTS rewrite is intentionally left for a later PR.

## Matched Profile Pairs

Only matched synthetic profile pairs are valid:

| products table | product_options table |
|---|---|
| `products_uniform` | `product_options_uniform` |
| `products_moderate_skew` | `product_options_moderate_skew` |
| `products_high_skew` | `product_options_high_skew` |

Cross-profile combinations are intentionally not supported.

## Reused Option Parameters

| profile | common option filters | less-common option filters |
|---|---|---|
| `products_uniform` | `BEIGE / L / IN_STOCK` | `WHITE / S / LOW_STOCK` |
| `products_moderate_skew` | `WHITE / L / OUT_OF_STOCK` | `GRAY / L / LOW_STOCK` |
| `products_high_skew` | `RED / M / IN_STOCK` | `BLACK / M / IN_STOCK` |

These values are the same profile-specific values used by the JOIN baseline experiment.

## Index Candidates

| candidate | columns | purpose |
|---|---|---|
| candidate 1: option filter first | `(color, size, stock_status, product_id)` | Tests whether filtering product_options by option values first can reduce JOIN input before joining to products. |
| candidate 2: join key first | `(product_id, color, size, stock_status)` | Tests whether a product_id-first index changes the plan when products filtering is selective enough for lookup-style access into product_options. |
| candidate 3: product_id only | `(product_id)` | Tests whether a pure JOIN-key index is useful without option filter columns. |
| candidate 4: stock/color/size/product | `(stock_status, color, size, product_id)` | Tests whether changing equality column order around low-cardinality `stock_status` affects planner choice. |

All index names use the `idx_exp_` prefix and are experiment-only.

## What This Experiment Intentionally Does Not Measure

This experiment does not measure production behavior, API p95 latency, k6 behavior, EXISTS rewrites, JOIN + keyset pagination, OpenSearch behavior, Redis behavior, read models, outbox behavior, monitoring, dashboarding, write overhead, or final index adoption.

JOIN + keyset pagination, API/k6, and OpenSearch are intentionally left for later PRs.

EXPLAIN Execution Time is not API p95 latency.

## Synthetic/Local Benchmark Caveat

These are synthetic benchmark profiles and must not be described as production-derived.

Results from local Docker/PostgreSQL are local experiment artifacts, not production performance claims.

## Cache Caveat

This experiment does not reset PostgreSQL shared_buffers or OS page cache between runs. Execution Time may be affected by warm cache state. Use plan shape, buffers, row counts, join/sort/distinct behavior, and execution time carefully.

## How To Run One Profile

Start PostgreSQL:

```powershell
docker compose up -d
```

Run the default profile, `products_moderate_skew`:

```powershell
.\db\experiments\a1-product-options-index-attempts\run-product-options-index-attempts.ps1
```

Run a specific profile:

```powershell
.\db\experiments\a1-product-options-index-attempts\run-product-options-index-attempts.ps1 -Profile products_uniform
```

## How To Run All Profiles

```powershell
.\db\experiments\a1-product-options-index-attempts\run-product-options-index-attempts.ps1 -Profile all
```

## Manual Command

```powershell
Get-Content -Raw db/experiments/a1-product-options-index-attempts/product_options_index_attempts.sql |
  docker compose exec -T postgres psql -U readpath -d readpath_lab -v products_table=products_moderate_skew -v product_options_table=product_options_moderate_skew
```

## How To Save Outputs

The PowerShell helper saves outputs under:

```text
db/experiments/a1-product-options-index-attempts/results/<profile>/
```

## Expected Artifact Naming

```text
<profile>_product_options_index_attempts_<YYYYMMDD_HHMMSS>.txt
```

Examples:

- `products_uniform_product_options_index_attempts_20260427_120000.txt`
- `products_moderate_skew_product_options_index_attempts_20260427_120000.txt`
- `products_high_skew_product_options_index_attempts_20260427_120000.txt`

## Cleanup Leftover Experiment Indexes

If a script is interrupted, clean up experiment indexes manually:

```powershell
docker compose exec postgres psql -U readpath -d readpath_lab -c "DROP INDEX IF EXISTS idx_exp_product_options_uniform_color_size_stock_product, idx_exp_product_options_uniform_product_color_size_stock, idx_exp_product_options_uniform_product_id, idx_exp_product_options_uniform_stock_color_size_product;"
docker compose exec postgres psql -U readpath -d readpath_lab -c "DROP INDEX IF EXISTS idx_exp_product_options_moderate_skew_color_size_stock_product, idx_exp_product_options_moderate_skew_product_color_size_stock, idx_exp_product_options_moderate_skew_product_id, idx_exp_product_options_moderate_skew_stock_color_size_product;"
docker compose exec postgres psql -U readpath -d readpath_lab -c "DROP INDEX IF EXISTS idx_exp_product_options_high_skew_color_size_stock_product, idx_exp_product_options_high_skew_product_color_size_stock, idx_exp_product_options_high_skew_product_id, idx_exp_product_options_high_skew_stock_color_size_product;"
```

Verify cleanup:

```powershell
docker compose exec postgres psql -U readpath -d readpath_lab -c "SELECT tablename, indexname FROM pg_indexes WHERE schemaname = 'public' AND indexname LIKE 'idx_exp_%' ORDER BY tablename, indexname;"
```

The expected cleanup result is zero rows.

## Next PR Recommendation

The next PR should compare JOIN + DISTINCT with an `EXISTS` rewrite, optionally carrying forward the most relevant experiment index candidate from these artifacts.

Do not jump to OpenSearch from this stage.
