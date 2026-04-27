# A-1b/A-1c Product Options EXISTS Rewrite Comparison

## Purpose

This experiment compares the existing naive products + product_options `JOIN + DISTINCT` query shape with an `EXISTS` rewrite for the same J1-J5 workload.

The narrow question is whether rewriting `JOIN + DISTINCT` into `EXISTS` changes plan shape, removes the `Unique`/DISTINCT node, and reduces row multiplication work under the same products + product_options filters.

This is a local DB-level EXPLAIN artifact PR. It is not an API implementation, API p95 claim, production behavior claim, OpenSearch decision, or final production index recommendation.

## Why JOIN + DISTINCT Exists In The Baseline

The baseline query joins products to product_options with a 1:N relationship. A product can match more than one option row, so `SELECT DISTINCT p.*` is used to remove duplicate product rows after the JOIN.

That makes duplicate removal part of the observed read path. The baseline intentionally keeps this naive shape so later experiments can compare alternatives against it.

## Why EXISTS Is A Rewrite Candidate

The listing query only needs products that have at least one matching option row. An `EXISTS` predicate can express that requirement without returning option rows into the outer result set.

The rewrite candidate keeps the same products filters, option filters, sort columns, LIMIT, and OFFSET. It only changes the option predicate shape from JOIN output rows plus DISTINCT to an existence test.

## Reused J1-J6 Workload

The workload reuses the intent and option parameters from the product_options JOIN baseline and product_options index attempts.

| case | shape |
|---|---|
| J1 | category/status/price/latest + option filters, `LIMIT 50 OFFSET 100` |
| J2 | category/brand/status/price/price ASC + option filters, `LIMIT 50 OFFSET 100` |
| J3 | category/status/review-count sort + option filters, `LIMIT 50 OFFSET 100` |
| J4 | category/status/price/latest + option filters, `LIMIT 50 OFFSET 10000` |
| J5 | broad active/latest listing + option filters, `LIMIT 50 OFFSET 100` |
| J6 | option selectivity/control counts |

J1-J5 run both versions:

- `JOIN + DISTINCT`
- `EXISTS`

J6 is a count/control section only. It helps explain option row multiplication and must not be treated as a performance benchmark.

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

These values are the same profile-specific values used by the prior JOIN baseline and index-attempt experiments.

## Experiment Index Families

This PR carries forward only two representative product_options index candidates from the previous PR:

| index family | columns | reason |
|---|---|---|
| option-filter-first | `(color, size, stock_status, product_id)` | Tests option predicate access before joining or checking product existence. |
| join-key-first | `(product_id, color, size, stock_status)` | Tests product-first lookup-style access into matching options. |

All indexes use the `idx_exp_` prefix and are experiment-only. They are created inside the experiment SQL and dropped after each index family.

This PR does not retest the product_id-only or stock_status-first candidates. The purpose here is query shape comparison, not another full index matrix.

## What This Experiment Measures

Focus on:

- whether `Unique`/DISTINCT disappears in the `EXISTS` version
- whether row multiplication is reduced or avoided
- whether PostgreSQL uses Semi Join, Nested Loop, Hash Join, Hash Semi Join, or another shape
- product_options access path
- sort behavior and temp I/O
- buffers and rows visible in EXPLAIN
- whether J5 remains a broad/heavy case
- profile-specific behavior across synthetic distributions

Execution Time is a secondary local signal. Do not interpret `EXPLAIN` Execution Time as API p95 latency.

## What This Experiment Intentionally Does Not Measure

This experiment does not measure production behavior, API p95 latency, k6 behavior, JOIN + keyset pagination, OpenSearch behavior, Redis behavior, read models, outbox behavior, monitoring, dashboarding, or final index adoption.

No permanent indexes, migrations, seed changes, or application code changes are added.

These are synthetic benchmark profiles and must not be described as production-derived.

This is not a cold-cache benchmark. The experiment does not reset PostgreSQL shared_buffers or OS page cache between runs.

## How To Run One Profile

Start PostgreSQL:

```powershell
docker compose up -d
```

Run the default profile, `products_moderate_skew`:

```powershell
.\db\experiments\a1-product-options-exists-rewrite-comparison\run-product-options-exists-rewrite-comparison.ps1
```

Run a specific profile:

```powershell
.\db\experiments\a1-product-options-exists-rewrite-comparison\run-product-options-exists-rewrite-comparison.ps1 -Profile products_uniform
```

## How To Run All Profiles

```powershell
.\db\experiments\a1-product-options-exists-rewrite-comparison\run-product-options-exists-rewrite-comparison.ps1 -Profile all
```

## Manual Command

```powershell
Get-Content -Raw db/experiments/a1-product-options-exists-rewrite-comparison/product_options_exists_rewrite_comparison.sql |
  docker compose exec -T postgres psql -U readpath -d readpath_lab -v products_table=products_moderate_skew -v product_options_table=product_options_moderate_skew
```

## Expected Artifacts

The PowerShell helper saves outputs under:

```text
db/experiments/a1-product-options-exists-rewrite-comparison/results/<profile>/
```

Expected filename format:

```text
<profile>_product_options_exists_rewrite_comparison_<YYYYMMDD_HHMMSS>.txt
```

## Cleanup Leftover Experiment Indexes

If a script is interrupted, clean up experiment indexes manually:

```powershell
docker compose exec postgres psql -U readpath -d readpath_lab -c "DROP INDEX IF EXISTS idx_exp_product_options_uniform_exists_color_size_stock_product, idx_exp_product_options_uniform_exists_product_color_size_stock;"
docker compose exec postgres psql -U readpath -d readpath_lab -c "DROP INDEX IF EXISTS idx_exp_product_options_moderate_skew_exists_color_size_stock_product, idx_exp_product_options_moderate_skew_exists_product_color_size_stock;"
docker compose exec postgres psql -U readpath -d readpath_lab -c "DROP INDEX IF EXISTS idx_exp_product_options_high_skew_exists_color_size_stock_product, idx_exp_product_options_high_skew_exists_product_color_size_stock;"
```

Verify cleanup:

```powershell
docker compose exec postgres psql -U readpath -d readpath_lab -c "SELECT tablename, indexname FROM pg_indexes WHERE schemaname = 'public' AND indexname LIKE 'idx_exp_%' ORDER BY tablename, indexname;"
```

The expected cleanup result is zero rows.

## What Not To Conclude Yet

Do not conclude API p95 improvement, production behavior, final index adoption, JOIN + keyset behavior, or an OpenSearch/read-model decision from this experiment.

## Next PR Recommendation

The next PR should use these artifacts to decide whether an EXISTS comparison should be expanded with a focused index candidate or whether JOIN + keyset should be explored separately.
