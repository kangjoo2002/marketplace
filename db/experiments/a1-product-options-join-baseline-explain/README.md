# A-1b Product Options JOIN Baseline EXPLAIN

## Purpose

This experiment records a baseline for naive products + product_options JOIN + DISTINCT query shapes.

This PR measures a naive JOIN + DISTINCT baseline. It does not optimize the JOIN yet.

The goal is to observe how the `product_options` 1:N relationship changes products search read-path behavior: JOIN fan-out, duplicate product rows, DISTINCT cost, option filter selectivity, sort behavior, and deep OFFSET with option filters.

## Why This Comes After Product Options Seed Profiles

The previous seed stage created deterministic synthetic option tables matching the existing products profiles. This experiment uses those matched pairs to measure the first JOIN baseline.

This experiment depends on the seeded tables:

- `products_uniform` + `product_options_uniform`
- `products_moderate_skew` + `product_options_moderate_skew`
- `products_high_skew` + `product_options_high_skew`

## What J1-J6 Measure

| case | shape | purpose |
|---|---|---|
| J1 | category/status/price/latest + option filters, `LIMIT 50 OFFSET 100` | Basic products search with option filters and duplicate removal. |
| J2 | category/brand/status/price/price ASC + option filters, `LIMIT 50 OFFSET 100` | Brand + option filters with price ordering and DISTINCT. |
| J3 | category/status/review-count sort + option filters, `LIMIT 50 OFFSET 100` | Option filters with review-count ordering. |
| J4 | category/status/price/latest + option filters, `LIMIT 50 OFFSET 10000` | JOIN + DISTINCT + deep OFFSET baseline. |
| J5 | broad active/latest listing + option filters, `LIMIT 50 OFFSET 100` | Broad active listing with option filters and duplicate removal. |
| J6 | option selectivity counts | Joined option rows, distinct products, and common vs less-common option combinations. |

## What JOIN Fan-Out Means

Each product can have multiple option rows. A naive JOIN can therefore produce multiple joined rows for one product before the result is reduced back to distinct products.

The verification stage showed each product has at least one option and average fan-out is around two options per product.

## Why SELECT DISTINCT Is Used

Listing queries use:

```sql
SELECT DISTINCT p.*
FROM <products_table> p
JOIN <product_options_table> po
  ON po.product_id = p.id
```

This intentionally models the naive baseline where duplicate product rows from a 1:N JOIN are removed by PostgreSQL.

This PR does not rewrite the query to `EXISTS`.

## What This Experiment Intentionally Does Not Measure

This experiment does not measure API p95 latency, k6 behavior, production behavior, write overhead, product_options index candidates, EXISTS rewrites, keyset pagination with JOIN, OpenSearch behavior, Redis behavior, read models, outbox behavior, or dashboard behavior.

product_options index tuning, EXISTS rewrite, keyset pagination with JOIN, API/k6, and OpenSearch are intentionally left for later PRs.

EXPLAIN Execution Time is not API p95 latency.

## Synthetic/Local Benchmark Caveat

These are synthetic benchmark profiles and must not be described as production-derived.

Results from local Docker/PostgreSQL are local experiment artifacts, not production performance claims.

## Matched Profile Pair Strategy

Only matched profile pairs are valid:

| products table | product_options table |
|---|---|
| `products_uniform` | `product_options_uniform` |
| `products_moderate_skew` | `product_options_moderate_skew` |
| `products_high_skew` | `product_options_high_skew` |

Cross-profile combinations are intentionally not supported.

## Option Parameter Selection Strategy

Seed verification artifacts were inspected before choosing option filters.

There was no single option combination that had enough rows for the category + brand shape across all three profiles. The SQL therefore uses profile-specific option combinations that are visible in seed verification artifacts and confirmed by count queries.

Common listing option filters:

| profile | color | size | stock_status | reason |
|---|---|---|---|---|
| `products_uniform` | `BEIGE` | `L` | `IN_STOCK` | Visible in category 35 and category 35 + brand 543 verification counts. |
| `products_moderate_skew` | `WHITE` | `L` | `OUT_OF_STOCK` | Visible with high counts in category 35 and category 35 + brand 543 verification counts. |
| `products_high_skew` | `RED` | `M` | `IN_STOCK` | Visible with high counts in category 35 and category 35 + brand 543 verification counts. |

Less-common J6 control filters:

| profile | color | size | stock_status |
|---|---|---|---|
| `products_uniform` | `WHITE` | `S` | `LOW_STOCK` |
| `products_moderate_skew` | `GRAY` | `L` | `LOW_STOCK` |
| `products_high_skew` | `BLACK` | `M` | `IN_STOCK` |

## How To Run One Profile

Start PostgreSQL:

```powershell
docker compose up -d
```

Run the default profile, `products_moderate_skew`:

```powershell
.\db\experiments\a1-product-options-join-baseline-explain\run-product-options-join-baseline-explain.ps1
```

Run a specific profile:

```powershell
.\db\experiments\a1-product-options-join-baseline-explain\run-product-options-join-baseline-explain.ps1 -Profile products_uniform
```

## How To Run All Profiles

```powershell
.\db\experiments\a1-product-options-join-baseline-explain\run-product-options-join-baseline-explain.ps1 -Profile all
```

## Manual Command

```powershell
Get-Content -Raw db/experiments/a1-product-options-join-baseline-explain/product_options_join_baseline_explain.sql |
  docker compose exec -T postgres psql -U readpath -d readpath_lab -v products_table=products_moderate_skew -v product_options_table=product_options_moderate_skew
```

## How To Save Outputs

The PowerShell helper saves outputs under:

```text
db/experiments/a1-product-options-join-baseline-explain/results/<profile>/
```

## Expected Artifact Naming

```text
<profile>_product_options_join_baseline_explain_<YYYYMMDD_HHMMSS>.txt
```

Examples:

- `products_uniform_product_options_join_baseline_explain_20260427_120000.txt`
- `products_moderate_skew_product_options_join_baseline_explain_20260427_120000.txt`
- `products_high_skew_product_options_join_baseline_explain_20260427_120000.txt`

## Next PR Recommendation

The next PR should compare either product_options index attempts or an `EXISTS` rewrite against this naive JOIN + DISTINCT baseline.

Do not jump to OpenSearch from this stage.
