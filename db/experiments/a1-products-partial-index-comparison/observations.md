# A-1a Products Partial Index Comparison Observations

## Scope

This document records observations from partial index experiment artifacts.

These are experiment candidates, not accepted production indexes. This is not a final index recommendation.

## Result Files

| profile | result file |
|---|---|
| `products_uniform` | `results/products_uniform/products_uniform_partial_index_comparison_20260427_120727.txt` |
| `products_moderate_skew` | `results/products_moderate_skew/products_moderate_skew_partial_index_comparison_20260427_120604.txt` |
| `products_high_skew` | `results/products_high_skew/products_high_skew_partial_index_comparison_20260427_120843.txt` |

## Observation Rules

- Only summarize facts visible in EXPLAIN outputs.
- Do not infer production behavior.
- Do not claim API p95 improvement.
- Do not compare EXPLAIN Execution Time with future OpenSearch API p95.
- Do not claim final index adoption from one query case.

## Candidate 1: active category/latest

Index:

```sql
(category_id, created_at DESC, id DESC) WHERE status = 'ACTIVE'
```

This candidate targets Q1 and Q4 by indexing active products in category/latest order while leaving `price` as a residual filter.

| query | observed plan shape | sort behavior | short observation |
|---|---|---|---|
| Q1 | `Index Scan` on this partial index for all three profiles | No explicit `Sort` node was visible for Q1 | The index matched `status = 'ACTIVE'`, `category_id`, and latest ordering; `price` remained a `Filter`. |
| Q4 | `Index Scan` for `products_moderate_skew` and `products_high_skew`; `Bitmap Heap Scan`/`Bitmap Index Scan` for `products_uniform` | No explicit `Sort` for moderate/high; `quicksort` remained for uniform | Deep OFFSET plan shape differed by profile. |
| Q2/Q3 | Bitmap access through this candidate appeared | `top-N heapsort` remained | The candidate is not aligned with price ordering or review-count ordering. |
| Q5/Q6 | `Parallel Seq Scan` remained visible | `Gather Merge` and `top-N heapsort` remained | This candidate does not target broad latest listing or price-only control. |

Visible details:

- Q1 `Rows Removed by Filter` was 75 on `products_uniform`, 70 on `products_moderate_skew`, and 100 on `products_high_skew`.
- Q4 `Rows Removed by Filter` was 5409 on `products_uniform`, 4270 on `products_moderate_skew`, and 4130 on `products_high_skew`.
- Q1 `EXPLAIN Execution Time` was 3.036 ms on `products_uniform`, 16.210 ms on `products_moderate_skew`, and 2.942 ms on `products_high_skew`.
- Q4 `EXPLAIN Execution Time` was 138.846 ms on `products_uniform`, 83.944 ms on `products_moderate_skew`, and 59.248 ms on `products_high_skew`.

What this suggests:

- This candidate was selected for the intended Q1 latest-ordering case on all profiles.
- The partial predicate removed `status` from the index scan condition surface, but `price` still had to be evaluated as a filter for Q1/Q4.
- Profile distribution affected Q4: uniform used bitmap access plus sort, while moderate/high used ordered index scan.

What not to conclude yet:

- This is not a final accepted index recommendation.
- This does not prove that deep OFFSET is solved.
- This does not prove API latency improvement.

## Candidate 2: active category/price/latest

Index:

```sql
(category_id, price, created_at DESC, id DESC) WHERE status = 'ACTIVE'
```

This candidate targets Q1 and Q4 by adding the `price` range column before the latest-ordering columns.

| query | observed plan shape | sort behavior | short observation |
|---|---|---|---|
| Q1 | Bitmap access through this partial index for all three profiles | `Sort` remained visible | The index included the `price` range, but final latest ordering still required sort work. |
| Q4 | Bitmap access through this partial index for all three profiles | `Sort` remained visible | Deep OFFSET still sorted rows in the artifacts. |
| Q2 | Bitmap access through this partial index for all three profiles | `Sort` remained visible | The candidate lacks `brand_id`, so it is not fully aligned with Q2. |
| Q5/Q6 | `Parallel Seq Scan` remained visible | Sort remained visible | This candidate does not target broad latest listing or price-only control. |

Visible details:

- Q1 `EXPLAIN Execution Time` was 34.296 ms on `products_uniform`, 151.847 ms on `products_moderate_skew`, and 174.136 ms on `products_high_skew`.
- Q4 `EXPLAIN Execution Time` was 28.250 ms on `products_uniform`, 146.609 ms on `products_moderate_skew`, and 208.306 ms on `products_high_skew`.
- Q2 still had sort behavior and `Rows Removed by Filter` for `brand_id`: 11576 on `products_uniform`, 16840 on `products_moderate_skew`, and 26843 on `products_high_skew`.

What this suggests:

- Including `price` let PostgreSQL use the price range in the partial index access path.
- Because `price` is a range column before `created_at DESC, id DESC`, Q1 and Q4 still showed explicit sort work in the artifacts.

What not to conclude yet:

- This is not proof that the candidate should be adopted.
- This does not answer whether keyset pagination is needed for Q4.

## Candidate 3: active category/brand/price

Index:

```sql
(category_id, brand_id, price ASC, id ASC) WHERE status = 'ACTIVE'
```

This candidate targets Q2 by aligning `category_id`, `brand_id`, and `price ASC, id ASC` for active products.

| query | observed plan shape | sort behavior | short observation |
|---|---|---|---|
| Q2 | `Index Scan` on this partial index for all three profiles | No explicit `Sort` node was visible for Q2 | This was the directly aligned candidate/query pair for Q2. |
| Q1/Q3/Q4 | Bitmap access through this candidate appeared | Sort remained visible | The candidate was considered for category-active subsets but was not aligned with latest or review-count ordering. |
| Q5/Q6 | `Parallel Seq Scan` remained visible | Sort remained visible | This candidate does not target broad latest listing or price-only control. |

Visible details:

- Q2 `EXPLAIN Execution Time` was 0.291 ms on `products_uniform`, 0.521 ms on `products_moderate_skew`, and 0.742 ms on `products_high_skew`.
- Q1 and Q4 still showed sort behavior when this candidate was the only experiment index.

What this suggests:

- A partial index can be selected when its predicate, equality filters, and ordering match the query shape.
- This observation is specific to Q2 in these artifacts.

What not to conclude yet:

- This does not prove workload-wide usefulness.
- This does not include write cost, storage cost, or production traffic considerations.

## Candidate 4: active category/review_count

Index:

```sql
(category_id, review_count DESC, id DESC) WHERE status = 'ACTIVE'
```

This candidate targets Q3 by aligning `category_id` and `review_count DESC, id DESC` for active products.

| query | observed plan shape | sort behavior | short observation |
|---|---|---|---|
| Q3 | `Index Scan` on this partial index for all three profiles | No explicit `Sort` node was visible for Q3 | This candidate aligned with Q3's active category/review-count order. |
| Q1/Q2/Q4 | Bitmap access through this candidate appeared | Sort remained visible | The candidate is not aligned with latest or price ordering. |
| Q5/Q6 | `Parallel Seq Scan` remained visible | Sort remained visible | This candidate does not target broad latest listing or price-only control. |

Visible details:

- Q3 `EXPLAIN Execution Time` was 0.362 ms on `products_uniform`, 0.589 ms on `products_moderate_skew`, and 0.560 ms on `products_high_skew`.
- Q1/Q2/Q4 showed sort behavior when this candidate was the only experiment index.

What this suggests:

- This candidate was selected for its intended Q3 query shape.
- It is not a general answer for latest-first or price-ordered query cases.

What not to conclude yet:

- This is not a final review-count index recommendation.
- This does not prove workload-wide usefulness.

## Candidate 5: active latest

Index:

```sql
(created_at DESC, id DESC) WHERE status = 'ACTIVE'
```

This candidate targets Q5, the broad active-products latest listing query.

| query | observed plan shape | sort behavior | short observation |
|---|---|---|---|
| Q5 | `Index Scan` on this partial index for all three profiles | No explicit `Sort` node was visible for Q5 | The candidate aligned with broad active latest ordering. |
| Q1 | `Index Scan` on this partial index for all three profiles | No explicit `Sort` node was visible for Q1 | Other filters were residual filters; row discard differed by profile. |
| Q4 | `Parallel Index Scan` on high skew; `Parallel Seq Scan`/sort on uniform and moderate | profile-dependent | The candidate did not consistently solve deep OFFSET. |
| Q2/Q3/Q6 | `Parallel Seq Scan` remained visible | Sort remained visible | This candidate is not aligned with price, review-count, or status-free price control. |

Visible details:

- Q5 `EXPLAIN Execution Time` was 1.385 ms on `products_uniform`, 0.377 ms on `products_moderate_skew`, and 0.464 ms on `products_high_skew`.
- Q1 `Rows Removed by Filter` was 124828 on `products_uniform`, 6060 on `products_moderate_skew`, and 5990 on `products_high_skew`.
- Q4 on `products_high_skew` used `Parallel Index Scan` on this candidate and recorded `EXPLAIN Execution Time` 1685.123 ms.
- Q4 on `products_uniform` and `products_moderate_skew` used `Parallel Seq Scan` with sort behavior.

What this suggests:

- The candidate was selected for the broad active latest Q5 query on all profiles.
- The same active/latest ordering can be selected for Q1, but category and price remain residual filters.
- Q4 remained profile-dependent and should not be considered solved from this candidate alone.

What not to conclude yet:

- Fast Q5 artifacts do not prove this index solves Q1/Q4.
- This is not an API latency claim.

## Q6 Control Case

Q6 has no `status = 'ACTIVE'` predicate:

```sql
WHERE price BETWEEN 10000 AND 100000
ORDER BY price ASC, id ASC
```

Across the generated artifacts, Q6 used `Parallel Seq Scan` with `Gather Merge` and `top-N heapsort` while each active-only partial index candidate was present.

Visible Q6 examples:

- Candidate 1 Q6 `EXPLAIN Execution Time`: 995.582 ms on `products_uniform`, 1293.061 ms on `products_moderate_skew`, 1174.261 ms on `products_high_skew`.
- Candidate 5 Q6 `EXPLAIN Execution Time`: 1721.757 ms on `products_uniform`, 941.005 ms on `products_moderate_skew`, 975.642 ms on `products_high_skew`.

What this confirms:

- In these artifacts, active-only partial indexes were not selected for the status-free Q6 control case.

What not to conclude yet:

- This does not say anything about a separate price-oriented index candidate.
- This does not measure API latency or production behavior.

## Cross-Candidate Summary

- Candidate 1 was selected for Q1 on all profiles. It was also selected for Q4 on `products_moderate_skew` and `products_high_skew`, while `products_uniform` used bitmap access plus sort for Q4.
- Candidate 2 used bitmap access for Q1 and Q4 on all profiles, but sort behavior remained visible.
- Candidate 3 was selected as an `Index Scan` for Q2 on all profiles and removed the visible sort for Q2.
- Candidate 4 was selected as an `Index Scan` for Q3 on all profiles and removed the visible sort for Q3.
- Candidate 5 was selected as an `Index Scan` for Q5 on all profiles and removed the visible sort for Q5.
- Q6 remained a status-free control case and used `Parallel Seq Scan` with sort behavior across the active-only partial index candidates.
- Q4 remained profile-dependent. Some candidates changed the access path, but these artifacts do not prove deep OFFSET is solved.
- `products_high_skew` showed more parallel bitmap behavior and visible `Rows Removed by Index Recheck` in several bitmap plans.
- These partial indexes have a smaller indexed row scope by definition because each candidate uses `WHERE status = 'ACTIVE'`. This statement is based on the documented index definitions, not on a measured index-size artifact.

This summary is limited to the committed EXPLAIN artifacts. It is not a final index adoption recommendation.

## Next Questions

- Does Q4 require keyset pagination even after partial indexes?
- Which candidate should be carried forward as a possible accepted DB index candidate later?
- Which profile shows the most different planner behavior?
- What should be measured by API/k6 later?
