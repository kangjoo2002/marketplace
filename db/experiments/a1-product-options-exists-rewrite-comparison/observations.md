# A-1b/A-1c Product Options EXISTS Rewrite Comparison Observations

## Scope

This document records local EXPLAIN observations comparing naive products + product_options `JOIN + DISTINCT` with an `EXISTS` rewrite.

The experiment uses matched synthetic profile pairs and two experiment-only product_options index families:

- option-filter-first: `(color, size, stock_status, product_id)`
- join-key-first: `(product_id, color, size, stock_status)`

This is not a final query recommendation, API p95 measurement, production behavior claim, OpenSearch decision, or read-model decision.

## Result Files

| profile | result file |
|---|---|
| `products_uniform` | `results/products_uniform/products_uniform_product_options_exists_rewrite_comparison_20260427_152140.txt` |
| `products_moderate_skew` | `results/products_moderate_skew/products_moderate_skew_product_options_exists_rewrite_comparison_20260427_152458.txt` |
| `products_high_skew` | `results/products_high_skew/products_high_skew_product_options_exists_rewrite_comparison_20260427_152756.txt` |

## Observation Rules

- Only summarize facts visible in EXPLAIN outputs or count outputs.
- Do not infer production behavior.
- Do not claim API p95 improvement.
- Do not invent improvement percentages.
- Do not choose a final production index.
- Do not claim OpenSearch is needed.

## Query Cases

| case | query shape |
|---|---|
| J1 | category/status/price/latest + option filters, `LIMIT 50 OFFSET 100` |
| J2 | category/brand/status/price/price ASC + option filters, `LIMIT 50 OFFSET 100` |
| J3 | category/status/review-count sort + option filters, `LIMIT 50 OFFSET 100` |
| J4 | category/status/price/latest + option filters, `LIMIT 50 OFFSET 10000` |
| J5 | broad active/latest listing + option filters, `LIMIT 50 OFFSET 100` |
| J6 | option selectivity/control counts |

## Option Parameters Used

| profile | common option filters | less-common option filters |
|---|---|---|
| `products_uniform` | `BEIGE / L / IN_STOCK` | `WHITE / S / LOW_STOCK` |
| `products_moderate_skew` | `WHITE / L / OUT_OF_STOCK` | `GRAY / L / LOW_STOCK` |
| `products_high_skew` | `RED / M / IN_STOCK` | `BLACK / M / IN_STOCK` |

## products_uniform

### option-filter-first

The `JOIN + DISTINCT` plans include `Unique` nodes for J1-J5. The `EXISTS` plans do not show `Unique`; J1, J3, J4, and J5 use `Parallel Hash Semi Join`, while J2 uses `Nested Loop Semi Join`.

| case | JOIN + DISTINCT Execution Time | EXISTS Execution Time | JOIN + DISTINCT shape | EXISTS shape | Unique in EXISTS |
|---|---:|---:|---|---|---|
| J1 | 3728.734 ms | 1325.639 ms | Parallel Hash Join + Unique | Parallel Hash Semi Join | no |
| J2 | 792.191 ms | 749.158 ms | Nested Loop + Unique | Nested Loop Semi Join | no |
| J3 | 878.602 ms | 974.485 ms | Parallel Hash Join + Unique | Parallel Hash Semi Join | no |
| J4 | 941.137 ms | 1110.794 ms | Parallel Hash Join + Unique | Parallel Hash Semi Join | no |
| J5 | 2816.421 ms | 2621.736 ms | Parallel Hash Join + Unique | Parallel Hash Semi Join | no |

J5 `JOIN + DISTINCT` uses `external merge` sort with temp read/write. The J5 `EXISTS` plan uses `top-N heapsort` and does not show temp read/write in this profile.

### join-key-first

The `JOIN + DISTINCT` plans include `Unique` nodes for J1-J5. The `EXISTS` plans do not show `Unique`; J1-J4 use `Nested Loop Semi Join`, while J5 uses `Parallel Hash Semi Join`.

| case | JOIN + DISTINCT Execution Time | EXISTS Execution Time | JOIN + DISTINCT shape | EXISTS shape | Unique in EXISTS |
|---|---:|---:|---|---|---|
| J1 | 848.493 ms | 769.342 ms | Nested Loop + Unique | Nested Loop Semi Join | no |
| J2 | 635.887 ms | 623.532 ms | Nested Loop + Unique | Nested Loop Semi Join | no |
| J3 | 597.384 ms | 703.871 ms | Nested Loop + Unique | Nested Loop Semi Join | no |
| J4 | 899.664 ms | 663.091 ms | Nested Loop + Unique | Nested Loop Semi Join | no |
| J5 | 3934.606 ms | 3493.310 ms | Parallel Hash Join + Unique | Parallel Hash Semi Join | no |

For J5, both versions scan product_options with option filters rather than using product_id-first lookup. The `JOIN + DISTINCT` plan shows `external merge` and temp read/write; the `EXISTS` plan uses `top-N heapsort` and does not show temp read/write.

## products_moderate_skew

### option-filter-first

The `JOIN + DISTINCT` plans include `Unique` nodes for J1-J5. The `EXISTS` plans do not show `Unique`; J1, J3, J4, and J5 use `Parallel Hash Semi Join`, while J2 uses `Nested Loop Semi Join`.

| case | JOIN + DISTINCT Execution Time | EXISTS Execution Time | JOIN + DISTINCT shape | EXISTS shape | Unique in EXISTS |
|---|---:|---:|---|---|---|
| J1 | 1766.753 ms | 639.029 ms | Parallel Hash Join + Unique | Parallel Hash Semi Join | no |
| J2 | 764.515 ms | 911.996 ms | Nested Loop + Unique | Nested Loop Semi Join | no |
| J3 | 809.542 ms | 654.282 ms | Parallel Hash Join + Unique | Parallel Hash Semi Join | no |
| J4 | 782.563 ms | 721.180 ms | Parallel Hash Join + Unique | Parallel Hash Semi Join | no |
| J5 | 2105.432 ms | 1926.565 ms | Parallel Hash Join + Unique | Parallel Hash Semi Join | no |

No `external merge` sort is visible for J5 in this profile under option-filter-first.

### join-key-first

The `JOIN + DISTINCT` plans include `Unique` nodes for J1-J5. The `EXISTS` plans do not show `Unique`; J1-J4 use `Nested Loop Semi Join`, while J5 uses `Parallel Hash Semi Join`.

| case | JOIN + DISTINCT Execution Time | EXISTS Execution Time | JOIN + DISTINCT shape | EXISTS shape | Unique in EXISTS |
|---|---:|---:|---|---|---|
| J1 | 677.298 ms | 853.622 ms | Nested Loop + Unique | Nested Loop Semi Join | no |
| J2 | 935.568 ms | 701.339 ms | Nested Loop + Unique | Nested Loop Semi Join | no |
| J3 | 626.764 ms | 525.726 ms | Nested Loop + Unique | Nested Loop Semi Join | no |
| J4 | 774.621 ms | 869.414 ms | Nested Loop + Unique | Nested Loop Semi Join | no |
| J5 | 4477.765 ms | 3237.093 ms | Parallel Hash Join + Unique | Parallel Hash Semi Join | no |

For J5, both versions scan product_options with option filters. The `EXISTS` plan removes `Unique`, but J5 remains broad because products-side `status = 'ACTIVE'` still reads a large input.

## products_high_skew

### option-filter-first

The `JOIN + DISTINCT` plans include `Unique` nodes for J1-J5. The `EXISTS` plans do not show `Unique`; J1, J3, J4, and J5 use `Parallel Hash Semi Join`, while J2 uses `Nested Loop Semi Join`.

| case | JOIN + DISTINCT Execution Time | EXISTS Execution Time | JOIN + DISTINCT shape | EXISTS shape | Unique in EXISTS |
|---|---:|---:|---|---|---|
| J1 | 1900.509 ms | 970.466 ms | Parallel Hash Join + Unique | Parallel Hash Semi Join | no |
| J2 | 628.293 ms | 812.489 ms | Nested Loop + Unique | Nested Loop Semi Join | no |
| J3 | 788.166 ms | 845.432 ms | Parallel Hash Join + Unique | Parallel Hash Semi Join | no |
| J4 | 892.390 ms | 1018.595 ms | Parallel Hash Join + Unique | Parallel Hash Semi Join | no |
| J5 | 3607.971 ms | 4099.748 ms | Parallel Hash Join + Unique | Parallel Hash Semi Join | no |

The `EXISTS` plans remove `Unique`, but high-skew option-filter-first plans show temp read/write in several semi-join cases because the parallel hash can batch. J5 remains broad and still shows temp I/O in the `EXISTS` plan.

### join-key-first

The `JOIN + DISTINCT` plans include `Unique` nodes for J1-J5. The `EXISTS` plans do not show `Unique`; J1-J4 use `Nested Loop Semi Join`, while J5 uses `Parallel Hash Semi Join`.

| case | JOIN + DISTINCT Execution Time | EXISTS Execution Time | JOIN + DISTINCT shape | EXISTS shape | Unique in EXISTS |
|---|---:|---:|---|---|---|
| J1 | 776.758 ms | 779.930 ms | Nested Loop + Unique | Nested Loop Semi Join | no |
| J2 | 834.813 ms | 766.327 ms | Nested Loop + Unique | Nested Loop Semi Join | no |
| J3 | 655.311 ms | 670.971 ms | Nested Loop + Unique | Nested Loop Semi Join | no |
| J4 | 1535.113 ms | 969.972 ms | Nested Loop + Unique | Nested Loop Semi Join | no |
| J5 | 5886.666 ms | 4562.299 ms | Parallel Hash Join + Unique | Parallel Hash Semi Join | no |

For J5, both versions scan product_options with option filters and show temp read/write. The `JOIN + DISTINCT` plan includes `external merge`; the `EXISTS` plan uses `top-N heapsort`, but the parallel hash still spills.

## J5 Broad Active Listing

J5 remains the broad stress case in the artifacts.

With option-filter-first, J5 uses product_options index access and `Parallel Hash Join` or `Parallel Hash Semi Join`. `EXISTS` removes `Unique`, but the broad products-side active scan remains.

With join-key-first, J5 does not use product_id lookup-style access for product_options. It scans product_options with option filters and joins or semi-joins against the broad active products input.

`products_high_skew` shows the most visible temp I/O in J5. In the join-key-first J5 case, both `JOIN + DISTINCT` and `EXISTS` show temp read/write.

## J6 Option Selectivity Control

The J6 counts below are count outputs, not performance benchmarks.

| profile | option set | global joined rows | global distinct products | Q1-shape distinct products | Q2-shape distinct products | option rows per distinct product |
|---|---|---:|---:|---:|---:|---:|
| `products_uniform` | `BEIGE / L / IN_STOCK` | 500001 | 500001 | 4214 | 339 | 1.0000 |
| `products_uniform` | `WHITE / S / LOW_STOCK` | 200000 | 200000 | 1442 | 120 | 1.0000 |
| `products_moderate_skew` | `WHITE / L / OUT_OF_STOCK` | 100000 | 100000 | 24250 | 13530 | 1.0000 |
| `products_moderate_skew` | `GRAY / L / LOW_STOCK` | 100000 | 100000 | 8610 | 2490 | 1.0000 |
| `products_high_skew` | `RED / M / IN_STOCK` | 700000 | 500000 | 13250 | 2030 | 1.4000 global |
| `products_high_skew` | `BLACK / M / IN_STOCK` | 4300000 | 3100000 | 4950 | 370 | 1.3871 global |

The high-skew profile shows global option row multiplication for the selected option sets. The Q1 and Q2 filtered shapes shown in J6 have 1.0000 option rows per distinct product for the displayed combinations.

## JOIN + DISTINCT vs EXISTS Summary

Across all generated artifacts, the `EXISTS` query removes the visible `Unique` nodes present in the `JOIN + DISTINCT` plans.

The replacement plan shape is not one single pattern. Under option-filter-first, most non-brand cases use `Parallel Hash Semi Join`, while J2 uses `Nested Loop Semi Join`. Under join-key-first, J1-J4 generally use `Nested Loop Semi Join`, while J5 uses `Parallel Hash Semi Join`.

Sort behavior changes in many `EXISTS` plans from a full `quicksort`/`external merge` over DISTINCT output to `top-N heapsort` for LIMIT/OFFSET ordering. This does not remove all sort or temp behavior; high-skew J5 still shows temp I/O.

## What This Suggests

The artifacts support the narrow observation that `EXISTS` removes the explicit result-level `Unique`/DISTINCT work for J1-J5 while preserving the same logical option existence filter.

The artifacts also show that avoiding result row multiplication does not eliminate all expensive work. Products-side scans, option selectivity, hash batching, sort behavior, and the chosen index family still matter.

J5 remains a broad listing stress case and should not be considered solved by this rewrite alone.

## What Not To Conclude Yet

- This is not API p95.
- This is not production behavior.
- This is not a final query recommendation.
- This is not a final index recommendation.
- This is not a JOIN + keyset result.
- This is not an OpenSearch decision.
- This is not a read-model decision.

## Next Questions

- Which index family should be carried forward if EXISTS is explored further?
- Does JOIN + keyset need a separate comparison after this?
- How should this eventually map to API/k6 after the API query shape exists?
