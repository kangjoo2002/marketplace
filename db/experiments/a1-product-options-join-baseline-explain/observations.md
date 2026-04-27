# A-1b Product Options JOIN Baseline EXPLAIN Observations

## Scope

This document records observations from products + product_options naive JOIN + DISTINCT baseline artifacts.

The experiment uses matched synthetic profile pairs only:

- `products_uniform` + `product_options_uniform`
- `products_moderate_skew` + `product_options_moderate_skew`
- `products_high_skew` + `product_options_high_skew`

This is not an optimization PR.

This is not API p95.

This is not production behavior.

## Result Files

| profile | result file |
|---|---|
| `products_uniform` | `results/products_uniform/products_uniform_product_options_join_baseline_explain_20260427_142051.txt` |
| `products_moderate_skew` | `results/products_moderate_skew/products_moderate_skew_product_options_join_baseline_explain_20260427_142007.txt` |
| `products_high_skew` | `results/products_high_skew/products_high_skew_product_options_join_baseline_explain_20260427_142139.txt` |

## Observation Rules

- Only summarize facts visible in EXPLAIN outputs or count outputs.
- Do not infer production behavior.
- Do not claim API p95 improvement.
- Do not claim final query design.
- Do not claim EXISTS or OpenSearch is needed yet.

## Query Cases

| case | query shape |
|---|---|
| J1 | `category_id = 35`, `status = ACTIVE`, `price BETWEEN 10000 AND 100000`, option filters, `ORDER BY created_at DESC, id DESC`, `LIMIT 50 OFFSET 100`, `SELECT DISTINCT p.*` |
| J2 | `category_id = 35`, `brand_id = 543`, `status = ACTIVE`, `price BETWEEN 10000 AND 100000`, option filters, `ORDER BY price ASC, id ASC`, `LIMIT 50 OFFSET 100`, `SELECT DISTINCT p.*` |
| J3 | `category_id = 35`, `status = ACTIVE`, option filters, `ORDER BY review_count DESC, id DESC`, `LIMIT 50 OFFSET 100`, `SELECT DISTINCT p.*` |
| J4 | `category_id = 35`, `status = ACTIVE`, `price BETWEEN 10000 AND 100000`, option filters, `ORDER BY created_at DESC, id DESC`, `LIMIT 50 OFFSET 10000`, `SELECT DISTINCT p.*` |
| J5 | `status = ACTIVE`, option filters, `ORDER BY created_at DESC, id DESC`, `LIMIT 50 OFFSET 100`, `SELECT DISTINCT p.*` |
| J6 | option selectivity control counts for common and less-common option combinations |

## Option Parameters Used

| profile | common option filters | less-common option filters | basis |
|---|---|---|---|
| `products_uniform` | `BEIGE / L / IN_STOCK` | `WHITE / S / LOW_STOCK` | Seed verification and count outputs. |
| `products_moderate_skew` | `WHITE / L / OUT_OF_STOCK` | `GRAY / L / LOW_STOCK` | Seed verification and count outputs. |
| `products_high_skew` | `RED / M / IN_STOCK` | `BLACK / M / IN_STOCK` | Seed verification and count outputs. |

There was no single option combination with enough rows for the category + brand query shape across all three profiles, so the SQL uses fixed profile-specific combinations.

## J1 Observation

| profile | plan shape | DISTINCT behavior | sort behavior | Execution Time |
|---|---|---|---|---:|
| `products_uniform` | `Parallel Hash Join` between filtered product_options and products | `Unique` above `Gather Merge`; worker-local `Unique` also visible | `quicksort` | 3090.415 ms |
| `products_moderate_skew` | `Parallel Hash Join` | `Unique` above `Gather Merge`; worker-local `Unique` also visible | `quicksort` | 1907.832 ms |
| `products_high_skew` | `Parallel Hash Join` | `Unique` above `Gather Merge`; worker-local `Unique` also visible | `quicksort` | 2270.463 ms |

Visible row details:

- `products_uniform`: join node emitted `1405` rows per loop across 3 loops.
- `products_moderate_skew`: join node emitted `8083` rows per loop across 3 loops.
- `products_high_skew`: join node emitted `4417` rows per loop across 3 loops.

## J2 Observation

| profile | plan shape | DISTINCT behavior | sort behavior | Execution Time |
|---|---|---|---|---:|
| `products_uniform` | `Parallel Hash Join` then `Gather` | `Unique` after `Sort` | `quicksort`, 56kB | 1657.327 ms |
| `products_moderate_skew` | `Parallel Hash Join` then `Gather` | `Unique` after `Sort` | `quicksort`, 1653kB | 1754.228 ms |
| `products_high_skew` | `Parallel Hash Join` then `Gather` | `Unique` after `Sort` | `quicksort`, 239kB | 2121.392 ms |

Visible row details:

- J6 count output shows common J2 distinct product counts of `339`, `13530`, and `2030` for uniform, moderate skew, and high skew respectively.
- The artifacts show `Rows Removed by Filter` on both product_options and products parallel sequential scans.

## J3 Observation

| profile | plan shape | DISTINCT behavior | sort behavior | Execution Time |
|---|---|---|---|---:|
| `products_uniform` | `Parallel Hash Join` | `Unique` above `Gather Merge`; worker-local `Unique` also visible | `quicksort` | 1646.194 ms |
| `products_moderate_skew` | `Parallel Hash Join` | `Unique` above `Gather Merge`; worker-local `Unique` also visible | `quicksort` | 1717.900 ms |
| `products_high_skew` | `Parallel Hash Join` | `Unique` above `Gather Merge`; worker-local `Unique` also visible | `quicksort` | 2014.367 ms |

J3 uses the review-count ordering, so sort work remains visible after the JOIN path.

## J4 Deep OFFSET Observation

| profile | plan shape | DISTINCT rows visible before limit | returned rows | sort behavior | Execution Time |
|---|---|---:|---:|---|---:|
| `products_uniform` | `Parallel Hash Join` + `Gather Merge` + `Unique` | 4214 | 0 | `quicksort` | 1707.322 ms |
| `products_moderate_skew` | `Parallel Hash Join` + `Gather Merge` + `Unique` | 10050 | 50 | `quicksort` | 1708.065 ms |
| `products_high_skew` | `Parallel Hash Join` + `Gather Merge` + `Unique` | 10050 | 50 | `quicksort` | 1880.145 ms |

`products_uniform` did not have enough distinct rows for `OFFSET 10000` under the selected option filters, so J4 returned 0 rows after doing the JOIN/DISTINCT work visible in the plan.

J4 is a candidate shape for later comparison, but this artifact alone does not decide whether keyset pagination or EXISTS is the final design.

## J5 Broad Active Listing Observation

| profile | plan shape | DISTINCT behavior | sort behavior | Execution Time |
|---|---|---|---|---:|
| `products_uniform` | `Parallel Hash Join` | `Unique` above `Gather Merge`; worker-local `Unique` also visible | `external merge`, temp read/write visible | 3080.056 ms |
| `products_moderate_skew` | `Parallel Hash Join` | `Unique` above `Gather Merge`; worker-local `Unique` also visible | `quicksort` | 2532.306 ms |
| `products_high_skew` | `Parallel Hash Join` | `Unique` above `Gather Merge`; worker-local `Unique` also visible | `external merge`, temp read/write visible | 5464.572 ms |

J5 broad active listing showed the largest visible temp sort pressure in the uniform and high-skew artifacts.

## J6 Option Selectivity Control

| profile | common global joined rows | common global distinct products | less-common global joined rows | less-common global distinct products |
|---|---:|---:|---:|---:|
| `products_uniform` | 500001 | 500001 | 200000 | 200000 |
| `products_moderate_skew` | 100000 | 100000 | 100000 | 100000 |
| `products_high_skew` | 700000 | 500000 | 4300000 | 3100000 |

| profile | common Q1 rows/products | common Q2 rows/products | less-common Q1 rows/products | less-common Q2 rows/products |
|---|---:|---:|---:|---:|
| `products_uniform` | 4214 / 4214 | 339 / 339 | 1442 / 1442 | 120 / 120 |
| `products_moderate_skew` | 24250 / 24250 | 13530 / 13530 | 8610 / 8610 | 2490 / 2490 |
| `products_high_skew` | 13250 / 13250 | 2030 / 2030 | 4950 / 4950 | 370 / 370 |

High skew is the only generated artifact where the global option combination count shows joined option rows greater than distinct product count:

- common global: `700000 / 500000 = 1.4000`
- less-common global: `4300000 / 3100000 = 1.3871`

For the narrower Q1/Q2 shapes, the visible joined rows and distinct product counts are equal in all three profiles.

## Cross-Profile Summary

All listing cases J1-J5 used parallel sequential scans and `Parallel Hash Join` rather than a product_options index access path. This matches the baseline setup: this PR does not add product_options query tuning indexes.

All listing cases showed `Unique` for `SELECT DISTINCT p.*`.

Uniform and high skew showed external merge sort in J5. Moderate skew J5 used quicksort in the artifact.

Profile-specific option filters materially changed row counts. For example, J6 common Q1 counts were `4214`, `24250`, and `13250` across uniform, moderate skew, and high skew.

## What This Suggests

The artifacts show that naive JOIN + DISTINCT introduces a new class of cost compared with products-only queries: product_options scan/filter, product join, duplicate removal, and post-join ordering.

DISTINCT is present because products can repeat after a 1:N JOIN.

Option selectivity matters, and profile skew affects visible joined rows and distinct product counts in these artifacts.

## What Not To Conclude Yet

- This is not API p95.
- This is not production behavior.
- This is not final query design.
- This is not an EXISTS conclusion.
- This is not an OpenSearch decision.
- This is not a product_options index tuning result.

## Next Questions

- Which product_options indexes should be tested next?
- How does EXISTS compare with JOIN + DISTINCT?
- How does keyset pagination behave with option filters?
- How should this eventually map to API/k6?
