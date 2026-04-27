# A-1a Products Keyset Pagination Comparison Observations

## Scope

This document records observations from Q4 OFFSET vs keyset pagination artifacts.

This is products-only.

This is not an API latency or p95 measurement.

This is not a final production pagination migration.

## Result Files

| profile | result file |
|---|---|
| `products_uniform` | `results/products_uniform/products_uniform_keyset_pagination_comparison_20260427_133052.txt` |
| `products_moderate_skew` | `results/products_moderate_skew/products_moderate_skew_keyset_pagination_comparison_20260427_133022.txt` |
| `products_high_skew` | `results/products_high_skew/products_high_skew_keyset_pagination_comparison_20260427_133203.txt` |

## Observation Rules

- Only summarize facts visible in EXPLAIN outputs.
- Do not infer production behavior.
- Do not claim API p95 improvement.
- Do not compare EXPLAIN Execution Time with future OpenSearch API p95.
- Do not claim final production adoption from this experiment.

## Query Shapes Compared

Q4 deep OFFSET query shape:

```sql
WHERE category_id = 35
  AND status = 'ACTIVE'
  AND price BETWEEN 10000 AND 100000
ORDER BY created_at DESC, id DESC
LIMIT 50 OFFSET 10000
```

Q4 keyset query shape:

```sql
WHERE category_id = 35
  AND status = 'ACTIVE'
  AND price BETWEEN 10000 AND 100000
  AND (created_at, id) < (:cursor_created_at, :cursor_id)
ORDER BY created_at DESC, id DESC
LIMIT 50
```

Cursor boundary rule:

- To simulate the same page as `OFFSET 10000 LIMIT 50`, derive the cursor from the last row before the target page.
- With `ORDER BY created_at DESC, id DESC`, derive the boundary using `OFFSET 9999 LIMIT 1`.

Supporting index used:

```sql
(category_id, created_at DESC, id DESC) WHERE status = 'ACTIVE'
```

The supporting index is experiment-only and is dropped after each run.

## Cursor Derivation

| profile | cursor_created_at | cursor_id | note |
|---|---|---:|---|
| `products_uniform` | `2024-11-11 18:44:55.43476` | `4726534` | Derived cursor is setup only. |
| `products_moderate_skew` | `2026-03-23 08:28:06.160229` | `805371` | Derived cursor is setup only. |
| `products_high_skew` | `2026-04-13 23:38:34.466094` | `388471` | Derived cursor is setup only. |

Reminder: the cursor derivation query is setup only and must not be interpreted as keyset read-path latency.

## OFFSET vs Keyset Results

| profile | OFFSET plan shape | keyset plan shape | OFFSET Execution Time | keyset Execution Time | key observation |
|---|---|---|---:|---:|---|
| `products_uniform` | `Bitmap Heap Scan` using the experiment index, then explicit `Sort` and `Limit` | `Index Scan` using the experiment index with row-value cursor in `Index Cond` | 127.337 ms | 0.289 ms | OFFSET sorted 12,599 filtered rows and returned 10,050 rows through the sort path; keyset used ordered index access and returned 50 rows. |
| `products_moderate_skew` | `Index Scan` using the experiment index, then `Limit` with deep OFFSET | `Index Scan` using the experiment index with row-value cursor in `Index Cond` | 23.625 ms | 0.192 ms | Both used ordered index access, but OFFSET scanned 10,050 qualifying rows while keyset scanned 50 returned rows. |
| `products_high_skew` | `Index Scan` using the experiment index, then `Limit` with deep OFFSET | `Index Scan` using the experiment index with row-value cursor in `Index Cond` | 16.497 ms | 0.195 ms | Both used ordered index access, but OFFSET scanned 10,050 qualifying rows while keyset scanned 50 returned rows. |

Result equivalence sanity check:

| profile | offset_page_count | keyset_page_count | ids_match |
|---|---:|---:|---|
| `products_uniform` | 50 | 50 | `t` |
| `products_moderate_skew` | 50 | 50 | `t` |
| `products_high_skew` | 50 | 50 | `t` |

Visible details:

- `products_uniform` OFFSET showed `Sort Method: quicksort Memory: 2058kB`, `Rows Removed by Filter: 5409`, and buffers `shared read=18101 written=10`.
- `products_uniform` keyset showed no explicit `Sort`, `Rows Removed by Filter: 22`, and buffers `shared hit=65 read=11`.
- `products_moderate_skew` OFFSET showed no explicit `Sort`, `Rows Removed by Filter: 4270`, and buffers `shared hit=14330 read=64`.
- `products_moderate_skew` keyset showed no explicit `Sort`, `Rows Removed by Filter: 20`, and buffers `shared hit=74`.
- `products_high_skew` OFFSET showed no explicit `Sort`, `Rows Removed by Filter: 4130`, and buffers `shared hit=14193 read=61`.
- `products_high_skew` keyset showed no explicit `Sort`, `Rows Removed by Filter: 10`, and buffers `shared hit=64 read=1`.

## Profile-Specific Observations

`products_uniform` differed from the skewed profiles for the OFFSET query: it used bitmap access plus an explicit sort. The keyset query used ordered index access in all three profiles.

`products_moderate_skew` and `products_high_skew` both used ordered index access for OFFSET and keyset, but the OFFSET query still had to advance to the deep page. The keyset query included the cursor boundary in the index condition.

## What This Suggests

These artifacts show that keyset pagination changed the Q4 read shape from deep OFFSET skipping to cursor-bounded ordered access when the supporting index was available.

The supporting index still matters. The keyset plans in these artifacts used `idx_exp_<target_table>_keyset_active_cat_created_id`.

Residual `price` filtering remained visible in both OFFSET and keyset plans because the supporting index does not include `price`.

## What Not To Conclude Yet

- This is not API p95.
- This is not production behavior.
- This is not final index adoption.
- This is not an OpenSearch decision.
- This is not product_options JOIN behavior.

## Next Questions

- Should this pagination shape be mapped to a products search API later?
- How should API/k6 compare OFFSET and keyset after the API exists?
- How does product_options JOIN affect pagination later?
