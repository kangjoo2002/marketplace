# A-1b Product Options Index Attempts Observations

## Scope

This document records observations from the products + product_options JOIN + DISTINCT workload with experiment-only product_options index candidates.

The experiment uses matched synthetic profile pairs only:

- `products_uniform` + `product_options_uniform`
- `products_moderate_skew` + `product_options_moderate_skew`
- `products_high_skew` + `product_options_high_skew`

This is not a final index recommendation.

This is not an EXISTS rewrite.

This is not API p95.

This is not production behavior.

## Result Files

| profile | result file |
|---|---|
| `products_uniform` | `results/products_uniform/products_uniform_product_options_index_attempts_20260427_145354.txt` |
| `products_moderate_skew` | `results/products_moderate_skew/products_moderate_skew_product_options_index_attempts_20260427_144911.txt` |
| `products_high_skew` | `results/products_high_skew/products_high_skew_product_options_index_attempts_20260427_145738.txt` |

## Observation Rules

- Only summarize facts visible in EXPLAIN outputs or count outputs.
- Do not infer production behavior.
- Do not claim API p95 improvement.
- Do not claim final index adoption.
- Do not claim EXISTS or OpenSearch is needed yet.

## Index Candidates

| candidate | columns | purpose |
|---|---|---|
| candidate 1: option filter first | `(color, size, stock_status, product_id)` | Tests option-filter-first access. |
| candidate 2: join key first | `(product_id, color, size, stock_status)` | Tests product-first lookup-style access. |
| candidate 3: product_id only | `(product_id)` | Tests pure JOIN-key access. |
| candidate 4: stock/color/size/product | `(stock_status, color, size, product_id)` | Tests alternate equality-column order. |

## Query Cases

| case | query shape |
|---|---|
| J1 | category/status/price/latest + option filters, `LIMIT 50 OFFSET 100`, `SELECT DISTINCT p.*` |
| J2 | category/brand/status/price/price ASC + option filters, `LIMIT 50 OFFSET 100`, `SELECT DISTINCT p.*` |
| J3 | category/status/review-count sort + option filters, `LIMIT 50 OFFSET 100`, `SELECT DISTINCT p.*` |
| J4 | category/status/price/latest + option filters, `LIMIT 50 OFFSET 10000`, `SELECT DISTINCT p.*` |
| J5 | broad active/latest listing + option filters, `LIMIT 50 OFFSET 100`, `SELECT DISTINCT p.*` |
| J6 | option selectivity control counts |

## Candidate 1 Observation: Option Filter First

Candidate 1 used `idx_exp_<product_options_table>_color_size_stock_product`.

Across all three profiles, J1, J3, J4, and J5 used a product_options `Index Only Scan` with the option equality predicates and a `Parallel Hash Join`. J2 used a `Nested Loop` with indexed product_options lookups.

`Unique` remained in the J1-J5 plans because the query shape stayed `SELECT DISTINCT p.*`. Sort behavior was mostly `quicksort`; J5 used `external merge` in `products_uniform` and `products_high_skew`.

| profile | J1 Execution Time | J2 Execution Time | J3 Execution Time | J4 Execution Time | J5 Execution Time |
|---|---:|---:|---:|---:|---:|
| `products_uniform` | 715.872 ms | 548.881 ms | 533.823 ms | 685.302 ms | 2142.713 ms |
| `products_moderate_skew` | 869.430 ms | 708.618 ms | 626.520 ms | 733.035 ms | 1513.893 ms |
| `products_high_skew` | 1564.913 ms | 752.112 ms | 575.666 ms | 627.703 ms | 3103.911 ms |

## Candidate 2 Observation: Join Key First

Candidate 2 used `idx_exp_<product_options_table>_product_color_size_stock`.

Across the result files, J1-J4 changed to `Nested Loop` plans with product_options index lookups. J5 remained a broad `Parallel Hash Join` shape and used a product_options sequential scan with option filters instead of using the candidate index for the product_options input.

`Unique` remained in J1-J5. Sort behavior was mostly `quicksort`; J5 used `external merge` in `products_uniform` and `products_high_skew`, and J3 also used `external merge` in `products_high_skew`.

| profile | J1 Execution Time | J2 Execution Time | J3 Execution Time | J4 Execution Time | J5 Execution Time |
|---|---:|---:|---:|---:|---:|
| `products_uniform` | 518.869 ms | 480.646 ms | 640.890 ms | 749.302 ms | 3399.313 ms |
| `products_moderate_skew` | 646.686 ms | 928.468 ms | 525.751 ms | 757.441 ms | 2474.461 ms |
| `products_high_skew` | 484.701 ms | 532.398 ms | 549.358 ms | 789.856 ms | 3872.913 ms |

## Candidate 3 Observation: Product ID Only

Candidate 3 used `idx_exp_<product_options_table>_product_id`.

Across the result files, J1-J4 used `Nested Loop` plans with product_id-based product_options access. Because the index does not contain option filter columns, the option predicates remain filter work after lookup. J5 remained a `Parallel Hash Join` with product_options sequential scan and option filters.

`Unique` remained in J1-J5. Sort behavior was mostly `quicksort`; J5 used `external merge` in `products_uniform` and `products_high_skew`, and J3 also used `external merge` in `products_high_skew`.

| profile | J1 Execution Time | J2 Execution Time | J3 Execution Time | J4 Execution Time | J5 Execution Time |
|---|---:|---:|---:|---:|---:|
| `products_uniform` | 537.834 ms | 498.042 ms | 537.575 ms | 572.023 ms | 2988.141 ms |
| `products_moderate_skew` | 565.640 ms | 722.453 ms | 537.356 ms | 616.168 ms | 2445.226 ms |
| `products_high_skew` | 503.251 ms | 545.822 ms | 455.807 ms | 844.389 ms | 3850.433 ms |

## Candidate 4 Observation: Stock/Color/Size/Product

Candidate 4 used `idx_exp_<product_options_table>_stock_color_size_product`.

Across all three profiles, J1, J3, J4, and J5 used a product_options `Index Only Scan` with option equality predicates and a `Parallel Hash Join`. J2 used a `Nested Loop` with indexed product_options lookups.

`Unique` remained in J1-J5. Sort behavior was mostly `quicksort`; J5 used `external merge` in `products_uniform` and `products_high_skew`.

| profile | J1 Execution Time | J2 Execution Time | J3 Execution Time | J4 Execution Time | J5 Execution Time |
|---|---:|---:|---:|---:|---:|
| `products_uniform` | 611.915 ms | 566.761 ms | 580.016 ms | 680.090 ms | 2278.915 ms |
| `products_moderate_skew` | 642.467 ms | 574.541 ms | 495.156 ms | 512.693 ms | 1501.786 ms |
| `products_high_skew` | 620.987 ms | 583.372 ms | 542.513 ms | 640.110 ms | 3309.689 ms |

## J6 Option Selectivity Control

The J6 counts below are count outputs, not performance benchmarks.

| profile | option set | global joined rows | global distinct products | Q1-shape distinct products | Q2-shape distinct products |
|---|---|---:|---:|---:|---:|
| `products_uniform` | `BEIGE` / `L` / `IN_STOCK` | 500001 | 500001 | 4214 | 339 |
| `products_uniform` | `WHITE` / `S` / `LOW_STOCK` | 200000 | 200000 | 1442 | 120 |
| `products_moderate_skew` | `WHITE` / `L` / `OUT_OF_STOCK` | 100000 | 100000 | 24250 | 13530 |
| `products_moderate_skew` | `GRAY` / `L` / `LOW_STOCK` | 100000 | 100000 | 8610 | 2490 |
| `products_high_skew` | `RED` / `M` / `IN_STOCK` | 700000 | 500000 | 13250 | 2030 |
| `products_high_skew` | `BLACK` / `M` / `IN_STOCK` | 4300000 | 3100000 | 4950 | 370 |

`products_high_skew` shows global option row multiplication for both listed option sets: `RED/M/IN_STOCK` has 1.4000 option rows per distinct product, and `BLACK/M/IN_STOCK` has 1.3871. In the Q1 and Q2 filtered shapes shown in J6, option rows per distinct product are 1.0000 for the displayed combinations.

## Cross-Candidate Summary

Candidate 1 and candidate 4 were chosen as option-filter-first `Index Only Scan` inputs for J1, J3, J4, and J5 across all profiles. J2 used `Nested Loop` lookup-style plans with those candidates.

Candidate 2 and candidate 3 changed J1-J4 toward product-first `Nested Loop` plans, but J5 did not use those indexes for the broad active listing; it used a product_options sequential scan with option filters and a `Parallel Hash Join`.

`Unique` remained in all J1-J5 plans because the query shape remained naive JOIN + DISTINCT.

Sort behavior did not disappear. J5 is the case where external merge/temp I/O appeared in `products_uniform` and `products_high_skew`. In `products_high_skew`, J3 also used external merge under candidate 2 and candidate 3.

Profile-specific differences are visible in the count outputs and EXPLAIN plans. `products_high_skew` has larger global option-row counts for the chosen option sets and shows temp I/O in more broad/sorted cases.

## What This Suggests

The artifacts show that product_options index column order can change the product_options access path and JOIN type for the same naive JOIN + DISTINCT workload.

The artifacts also show that DISTINCT/Unique remains a separate cost because the query still joins a 1:N options table and requests `SELECT DISTINCT p.*`.

The broad active listing case, J5, remains a useful stress case for later comparison because it keeps large products-side input and can still require broad sort/Unique work even when product_options uses an option-filter index.

These observations do not answer the EXISTS rewrite question.

## What Not To Conclude Yet

- This is not API p95.
- This is not production behavior.
- This is not a final index recommendation.
- This is not an EXISTS conclusion.
- This is not an OpenSearch decision.
- This is not a JOIN + keyset result.

## Next Questions

- How does JOIN + DISTINCT compare with EXISTS?
- Which index candidate should be carried forward into EXISTS comparison?
- How does JOIN + keyset behave later?
- How should this eventually map to API/k6?
