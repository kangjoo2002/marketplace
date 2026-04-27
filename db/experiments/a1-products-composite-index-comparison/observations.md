# A-1a Products Composite Index Comparison Observations

## Scope

This document records observations from composite index experiment artifacts.

These are experiment candidates, not accepted production indexes. This is not a final index recommendation.

## Result Files

| profile | result file |
|---|---|
| `products_uniform` | `results/products_uniform/products_uniform_composite_index_comparison_20260427_112426.txt` |
| `products_moderate_skew` | `results/products_moderate_skew/products_moderate_skew_composite_index_comparison_20260427_112237.txt` |
| `products_high_skew` | `results/products_high_skew/products_high_skew_composite_index_comparison_20260427_112603.txt` |

## Observation Rules

- Only summarize facts visible in EXPLAIN outputs.
- Do not infer production behavior.
- Do not claim API p95 improvement.
- Do not compare EXPLAIN Execution Time with future OpenSearch API p95.
- Do not claim final index adoption from one query case.

## Candidate 1: category/status/latest

Index:

```sql
(category_id, status, created_at DESC, id DESC)
```

This candidate is aimed at Q1 and Q4, where `category_id` and `status` are equality filters and the result order is latest-first.

| query | observed plan shape | sort behavior | short observation |
|---|---|---|---|
| Q1 | `Index Scan` on this candidate for all three profiles | No explicit `Sort` node was visible for Q1 | The index matched the equality filters and latest ordering, but `price` remained a `Filter`. |
| Q4 | `Index Scan` for `products_moderate_skew` and `products_high_skew`; `Bitmap Heap Scan`/`Bitmap Index Scan` for `products_uniform` | No explicit `Sort` for moderate/high; `Sort` remained for uniform | Deep OFFSET did not have a single stable plan shape across profiles. |
| Q2/Q3 | Bitmap access appeared in the result files, followed by sort | `top-N heapsort` remained visible | The candidate is not aligned with Q2 price ordering or Q3 review-count ordering. |
| Q5/Q6 | `Parallel Seq Scan` remained visible | Sort remained visible | This candidate does not target broad status-only or price-only control cases. |

Visible details:

- Q1 kept `price` as a residual filter. The result files show `Rows Removed by Filter` for Q1: 75 on `products_uniform`, 70 on `products_moderate_skew`, and 100 on `products_high_skew`.
- Q4 also kept `price` as a residual filter when the index scan path was used. `Rows Removed by Filter` was 4270 on `products_moderate_skew` and 4130 on `products_high_skew`.
- Q4 on `products_uniform` used bitmap access and still had a `Sort` node, with `EXPLAIN Execution Time` 82.770 ms.
- Q4 on `products_moderate_skew` used the index scan path, with `EXPLAIN Execution Time` 68.542 ms.
- Q4 on `products_high_skew` used the index scan path, with `EXPLAIN Execution Time` 64.618 ms.

What this suggests:

- The candidate can support Q1 latest ordering after `category_id` and `status` filtering.
- For Q1/Q4, leaving `price` outside the index key prefix means PostgreSQL still has to evaluate the price range as a filter.
- Profile distribution can affect whether PostgreSQL chooses an ordered index scan or bitmap access plus sort.

What not to conclude yet:

- This is not a final recommendation for a production index.
- This does not prove that deep OFFSET is solved.
- This does not prove API latency improvement.

## Candidate 2: category/status/price/latest

Index:

```sql
(category_id, status, price, created_at DESC, id DESC)
```

This candidate is aimed at Q1 and Q4 with `price` included before the latest-ordering columns.

| query | observed plan shape | sort behavior | short observation |
|---|---|---|---|
| Q1 | Bitmap access through this candidate for all three profiles | `Sort` remained visible | Including `price` helped the index condition include the price range, but did not satisfy the final latest ordering. |
| Q4 | Bitmap access through this candidate for all three profiles | `Sort` remained visible | Deep OFFSET still required sorting in these artifacts. |
| Q2 | Bitmap access through this candidate for all three profiles | `Sort` remained visible | The index lacks `brand_id`, so it is not fully aligned with Q2. |
| Q5/Q6 | `Parallel Seq Scan` remained visible | Sort remained visible | This candidate does not target broad status-only or price-only control cases. |

Visible details:

- Q1 used bitmap access and a `Sort` node on all profiles.
- Q4 used bitmap access and a `Sort` node on all profiles.
- Q1 `EXPLAIN Execution Time` was 45.631 ms on `products_uniform`, 221.617 ms on `products_moderate_skew`, and 668.600 ms on `products_high_skew`.
- Q4 `EXPLAIN Execution Time` was 27.536 ms on `products_uniform`, 211.160 ms on `products_moderate_skew`, and 317.750 ms on `products_high_skew`.
- `products_high_skew` showed `Parallel Bitmap Heap Scan` in several cases.

What this suggests:

- Adding `price` lets PostgreSQL constrain the index scan by the price range.
- Because `price` is a range column before `created_at DESC, id DESC`, the result files still show explicit sort work for Q1 and Q4.
- This candidate is useful for comparing filtering reduction against ordering support, not for making a final index decision.

What not to conclude yet:

- A lower EXPLAIN time for one query/profile is not enough to adopt this index.
- This does not answer whether a partial index would be better.
- This does not answer whether Q4 should move to keyset pagination.

## Candidate 3: category/brand/status/price

Index:

```sql
(category_id, brand_id, status, price ASC, id ASC)
```

This candidate is aimed at Q2, where equality filters include `category_id`, `brand_id`, and `status`, and the result order is `price ASC, id ASC`.

| query | observed plan shape | sort behavior | short observation |
|---|---|---|---|
| Q2 | `Index Scan` on this candidate for all three profiles | No explicit `Sort` node was visible for Q2 | This was the most directly aligned candidate/query pair in the artifacts. |
| Q1/Q3/Q4 | Bitmap access appeared in the result files | Sort remained visible | The candidate can be considered by the planner, but it is not aligned with latest or review-count ordering. |
| Q5/Q6 | `Parallel Seq Scan` remained visible | Sort remained visible | This candidate does not target broad status-only or price-only control cases. |

Visible details:

- Q2 used `Index Scan` on this candidate for all three profiles.
- Q2 had no explicit `Sort` node in the summarized result sections.
- Q2 `EXPLAIN Execution Time` was 0.285 ms on `products_uniform`, 0.478 ms on `products_moderate_skew`, and 0.546 ms on `products_high_skew`.
- Q1, Q3, and Q4 still showed bitmap access plus sort when this candidate was the only experiment index.
- Q5 and Q6 continued to use broad parallel scan paths.

What this suggests:

- Equality columns followed by the same ordering columns used by the query can give PostgreSQL a more aligned access path.
- This candidate is specifically relevant to Q2 and should not be generalized to the full Q1~Q6 workload.

What not to conclude yet:

- This does not prove this index should be permanently adopted.
- This does not solve Q1, Q3, Q4, Q5, or Q6 as a workload-wide answer.
- This does not include write cost, storage cost, or production traffic considerations.

## Candidate 4: category/status/review_count

Index:

```sql
(category_id, status, review_count DESC, id DESC)
```

This candidate is aimed at Q3, where equality filters are `category_id` and `status`, and the result order is `review_count DESC, id DESC`.

| query | observed plan shape | sort behavior | short observation |
|---|---|---|---|
| Q3 | `Index Scan` on this candidate for all three profiles | No explicit `Sort` node was visible for Q3 | This candidate aligned with Q3's filter and sort shape. |
| Q1/Q2/Q4 | Bitmap access appeared in the result files | Sort remained visible | The candidate is not aligned with latest ordering or price ordering. |
| Q5/Q6 | `Parallel Seq Scan` remained visible | Sort remained visible | This candidate does not target broad status-only or price-only control cases. |

Visible details:

- Q3 used `Index Scan` on this candidate for all three profiles.
- Q3 had no explicit `Sort` node in the summarized result sections.
- Q3 `EXPLAIN Execution Time` was 0.377 ms on `products_uniform`, 0.481 ms on `products_moderate_skew`, and 0.513 ms on `products_high_skew`.
- Q1, Q2, and Q4 still showed bitmap access plus sort when this candidate was the only experiment index.
- `products_high_skew` showed `Rows Removed by Index Recheck` in several bitmap access plans, including Q1/Q2/Q4.

What this suggests:

- This candidate is well aligned with the Q3 review-count sort case.
- It is not a workload-wide answer because most other query cases order by different columns.

What not to conclude yet:

- This does not prove that a review-count index should be adopted.
- It does not address latest-first or price-ordered query cases.
- It does not measure write overhead or production behavior.

## Cross-Candidate Summary

- Candidate 1 was selected as an ordered `Index Scan` for Q1 on all profiles. It was also selected as an ordered `Index Scan` for Q4 on `products_moderate_skew` and `products_high_skew`, while `products_uniform` used bitmap access plus sort for Q4.
- Candidate 2 was used through bitmap access for Q1 and Q4 on all profiles, but sort work remained visible. The artifacts are consistent with the caveat that a range column before sort columns may limit how much of the final `ORDER BY created_at DESC, id DESC` can be satisfied by the index order.
- Candidate 3 was selected as an `Index Scan` for Q2 on all profiles and removed the visible sort for Q2.
- Candidate 4 was selected as an `Index Scan` for Q3 on all profiles and removed the visible sort for Q3.
- Q5 and Q6 remained broad control cases in this experiment. The tested composite candidates did not target those query shapes, and `Parallel Seq Scan` remained visible for them.
- Q4 remained the main deep OFFSET comparison case. Some candidates changed the access path, but the artifacts do not prove that deep OFFSET is solved.
- `products_high_skew` showed more parallel bitmap behavior and visible `Rows Removed by Index Recheck` in several bitmap plans, so profile distribution affected plan shape.

This summary is limited to the committed EXPLAIN artifacts. It is not a final index adoption recommendation.

## Next Questions

- Should partial indexes be tested next?
- Which candidate should be compared with partial index?
- Does Q4 require keyset pagination even after composite indexes?
- Which profile shows the most different planner behavior?
