# A-1c JOIN/EXISTS Keyset Pagination Observations

## Scope

This document is for observations from the products + product_options EXISTS OFFSET vs keyset pagination artifacts.

This is a DB-only PostgreSQL `EXPLAIN ANALYZE` experiment. It is not an API latency or p95 measurement, not a production benchmark, and not a final index decision.

## Result Files

| profile | result file |
|---|---|
| `products_uniform` | `results/products_uniform/products_uniform_join_keyset_pagination_20260427_162143.txt` |
| `products_moderate_skew` | `results/products_moderate_skew/products_moderate_skew_join_keyset_pagination_20260427_162143.txt` |
| `products_high_skew` | `results/products_high_skew/products_high_skew_join_keyset_pagination_20260427_162143.txt` |

## Observation Rules

- Only summarize facts visible in the generated EXPLAIN outputs.
- Do not infer production behavior.
- Do not claim API p95 improvement.
- Do not make final production index recommendations.
- Do not compare these local DB artifacts with future OpenSearch or API results.

## Cases

| case | shape |
|---|---|
| K1 | category/status/price + less-common option filters, `LIMIT 50 OFFSET 100` |
| K2 | active listing + common option filters, `LIMIT 50 OFFSET 100` |
| K3 | active listing + common option filters, `LIMIT 50 OFFSET 10000` |

All cases use `EXISTS` for option filtering and `ORDER BY created_at DESC, id DESC`.

## Index Families

Option index families:

- option-filter-first: `(color, size, stock_status, product_id)`
- join-key-first: `(product_id, color, size, stock_status)`

Supporting products pagination index:

- `(created_at DESC, id DESC) WHERE status = 'ACTIVE'`

All indexes are experiment-only and are dropped by the SQL.

## Result Equivalence

All generated artifacts report matching page IDs for the OFFSET page and the keyset page:

| profile | index family | case | offset_page_count | keyset_page_count | ids_match |
|---|---|---|---:|---:|---|
| `products_uniform` | option-filter-first | K1 | 50 | 50 | `t` |
| `products_uniform` | option-filter-first | K2 | 50 | 50 | `t` |
| `products_uniform` | option-filter-first | K3 | 50 | 50 | `t` |
| `products_uniform` | join-key-first | K1 | 50 | 50 | `t` |
| `products_uniform` | join-key-first | K2 | 50 | 50 | `t` |
| `products_uniform` | join-key-first | K3 | 50 | 50 | `t` |
| `products_moderate_skew` | option-filter-first | K1 | 50 | 50 | `t` |
| `products_moderate_skew` | option-filter-first | K2 | 50 | 50 | `t` |
| `products_moderate_skew` | option-filter-first | K3 | 50 | 50 | `t` |
| `products_moderate_skew` | join-key-first | K1 | 50 | 50 | `t` |
| `products_moderate_skew` | join-key-first | K2 | 50 | 50 | `t` |
| `products_moderate_skew` | join-key-first | K3 | 50 | 50 | `t` |
| `products_high_skew` | option-filter-first | K1 | 50 | 50 | `t` |
| `products_high_skew` | option-filter-first | K2 | 50 | 50 | `t` |
| `products_high_skew` | option-filter-first | K3 | 50 | 50 | `t` |
| `products_high_skew` | join-key-first | K1 | 50 | 50 | `t` |
| `products_high_skew` | join-key-first | K2 | 50 | 50 | `t` |
| `products_high_skew` | join-key-first | K3 | 50 | 50 | `t` |

The SQL raises an exception if any `ids_match` value is false.

## EXPLAIN Observations

Visible facts from the generated artifacts:

- The measured query text uses `EXISTS`; it does not use `SELECT DISTINCT`.
- The artifacts do not show a DISTINCT/duplicate-removal `Unique` plan node. `Inner Unique: true` appears in some nested-loop plans, but that is join metadata, not DISTINCT work.
- K3 is the deep page case and is the clearest place to inspect skipped-row behavior.
- K3 OFFSET plans return rows after advancing to `OFFSET 10000`; K3 keyset plans use the derived cursor boundary and return the same next-page IDs.
- The keyset cursor boundary is visible as a row-value comparison against `created_at` and `id`.
- Sort behavior is profile- and index-family-dependent. The artifacts show in-memory `top-N heapsort` and `quicksort` where Sort nodes appear; no `external merge` sort was observed in the generated files.
- The final cleanup section reports zero remaining `idx_exp_%` indexes for each profile run.

## What Not To Conclude

Do not conclude API p95 improvement, production performance, final index adoption, or search architecture migration from these artifacts.

This experiment only answers whether local PostgreSQL plans for the narrowed EXISTS option-filter shape show different skipped-row behavior between OFFSET and keyset pagination.
