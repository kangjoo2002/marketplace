# A-1 Product Search Denormalized Read Table Observations

## Scope

This document records observations for the PostgreSQL-internal read table:

```text
product_search_documents_moderate_skew
```

Scope is `moderate_skew` only.

This PR does not claim production-ready denormalization or real-time freshness.
It validates a PostgreSQL-internal read model for the moderate_skew benchmark profile only.

The success criteria are result equivalence with the normalized source query,
removal of read-time JOIN/EXISTS from the search path, documented query-plan behavior,
and documented rebuild/freshness/rollback limitations.

Sort elimination and p95 improvement are expected outcomes to observe, not required success criteria.

## Repository Schema Adaptation

`product_options_moderate_skew` has no `updated_at` column in this repository.

Adaptation:

- `source_updated_at` is populated from `products_moderate_skew.updated_at`.
- `max_option_updated_at` is reported as `NULL` with a note in dataset fingerprint output.

## Option Signature Rule

`option_signatures` stores signatures as:

```text
{color}|{size}|{stock_status}
```

Example:

```text
BLACK|M|IN_STOCK
```

The helper function is `make_product_option_signature(TEXT, TEXT, TEXT)`.

Delimiter assumption:

- `|` is reserved as the delimiter.
- Validation checks `color`, `size`, and `stock_status` for delimiter collisions.

Separate `colors[]`, `sizes[]`, and `stock_statuses[]` arrays are intentionally not used because they can create false positives when values come from different option rows.

## Products Without Options Policy

Chosen policy: Option A.

The benchmark seed generates at least one option per product, so backfill uses an inner join and expects:

```text
products_without_options = 0
```

This is a benchmark-profile assumption. It is not a production data model claim.

## Result Files

One successful backfill artifact was generated:

```text
results/20260429_124709/product_search_documents_moderate_skew_backfill_20260429_124709.txt
```

Interrupted validation artifacts were removed because the command did not finish successfully.

Successful section-level validation artifacts:

```text
results/20260429_135038/product_search_documents_moderate_skew_validate_cheap_20260429_135038.txt
results/20260429_135121/product_search_documents_moderate_skew_validate_product_id_set_20260429_135121.txt
results/20260429_135141/product_search_documents_moderate_skew_validate_equivalence_b1_20260429_135141.txt
results/20260429_135152/product_search_documents_moderate_skew_validate_equivalence_b2_20260429_135152.txt
results/20260429_135201/product_search_documents_moderate_skew_validate_equivalence_b3_20260429_135201.txt
results/20260429_140137/product_search_documents_moderate_skew_validate_signature_count_20260429_140137.txt
results/20260429_140303/product_search_documents_moderate_skew_explain_20260429_140303.txt
```

Future successful artifacts should be recorded under:

```text
results/<YYYYMMDD_HHMMSS>/
```

## Backfill Result

| field | value |
|---|---|
| backfill started_at | `2026-04-29 03:47:24.738709+00` |
| backfill finished_at | `2026-04-29 03:49:46.959754+00` |
| backfill duration | `00:02:22.221045` |
| backfilled rows | `10000000` |
| backfill rows/sec | `70313.08` |
| ANALYZE executed_at | `2026-04-29 03:49:46.425823+00` |

## Validation Result

Required section-level validation completed. `validate-all` and multi-offset equivalence were intentionally not run.

The validation SQL has been refactored after the interrupted run:

- missing/extra product-id sets are materialized once into temporary tables and reused for examples and counts.
- signature-count mismatches are materialized once into a temporary table and reused for examples and counts.
- B1, B2, and B3 equivalence checks are split into explicit query blocks with fixed deterministic ordering.
- default equivalence checks remain limited to B1 offset `100`, B2 offset `100`, and B3 offset `10000`.
- `statement_timeout = '10min'` is set to avoid another indefinite local run.
- the runner now exposes explicit actions: `validate-cheap`, `validate-product-id-set`, `validate-signature-count`, `validate-equivalence-b1`, `validate-equivalence-b2`, `validate-equivalence-b3`, and `validate-all`.

Only completed actions are recorded below.

| check | result |
|---|---|
| source/read row count match | `true`; products count `10000000`, read table count `10000000` from `validate-cheap` |
| one row per product enforcement | primary key `product_search_documents_moderate_skew_pkey`, `PRIMARY KEY (product_id)` from `validate-cheap` |
| source/read product_id set match | `true`; missing_from_read_count `0`, extra_in_read_count `0` from `validate-product-id-set` |
| duplicate product_id | enforced by primary key; duplicate count query not run as a separate full scan |
| products_without_options | `0` from `validate-cheap` |
| chosen products_without_options policy | Option A |
| option_signatures null count | `0` from `validate-cheap` |
| option_signatures empty count | `0` from `validate-cheap` |
| delimiter collision count | `0` from `validate-cheap` |
| signature_count_mismatch | `0` from standalone `validate-signature-count` |
| B1 equivalence | `ids_match = true`, source_page_count `50`, read_page_count `50`, offset `100` |
| B2 equivalence | `ids_match = true`, source_page_count `50`, read_page_count `50`, offset `100` |
| B3 equivalence | `ids_match = true`, source_page_count `50`, read_page_count `50`, offset `10000` |
| multi-offset equivalence | Not run; removed from default validation as not feasible in this local run |
| validate-all | Not run |

The `validate-signature-count` section was run separately because it is the heaviest validation section. It groups `product_options_moderate_skew` by `product_id` across the 20.5M-row option table and compares source distinct option-combination counts with read-table `option_signatures` cardinality. The section completed successfully in `01:03.039` for the mismatch materialization query and returned `signature_count_mismatch = 0`.

## Query Shape Observation

The denormalized validation and EXPLAIN queries read from:

```text
product_search_documents_moderate_skew
```

The read-table queries filter options with:

```sql
option_signatures @> ARRAY[make_product_option_signature(...)]
```

They do not include a read-time `JOIN` to `product_options_moderate_skew` and do not include a read-time `EXISTS` subquery.

The `validate-cheap` artifact records this as `SQL_SHAPE_ASSERTION` with `verification_type = manual_review_required`. It is a SQL-shape assertion, not a database-executed proof of plan behavior. Plan behavior is recorded in the EXPLAIN Summary section below.

## EXPLAIN Summary

| scenario | read-time JOIN removed? | read-time EXISTS removed? | option GIN used? | scenario index used? | Sort behavior | residual filter | artifact |
|---|---|---|---|---|---|---|---|
| B1 | yes; no product_options join in the denormalized query or plan | yes; no product_options EXISTS/subplan in the denormalized query or plan | no; option predicate is a residual filter | `idx_psd_moderate_skew_active_cat_brand_review` | no `Sort` node observed; index order satisfies `review_count DESC, product_id DESC` | `price` range and `option_signatures @>` filter; Rows Removed by Filter `94` | `results/20260429_140303/product_search_documents_moderate_skew_explain_20260429_140303.txt` |
| B2 | yes; no product_options join in the denormalized query or plan | yes; no product_options EXISTS/subplan in the denormalized query or plan | no; option predicate is a residual filter | `idx_psd_moderate_skew_active_created` | no `Sort` node observed; index order satisfies `created_at DESC, product_id DESC` | `option_signatures @>` filter; Rows Removed by Filter `540` | `results/20260429_140303/product_search_documents_moderate_skew_explain_20260429_140303.txt` |
| B3 | yes; no product_options join in the denormalized query or plan | yes; no product_options EXISTS/subplan in the denormalized query or plan | no; option predicate is a residual filter | `idx_psd_moderate_skew_active_cat_brand_review` | no `Sort` node observed; index order satisfies `review_count DESC, product_id DESC` | `price` range and `option_signatures @>` filter; Rows Removed by Filter `6820` | `results/20260429_140303/product_search_documents_moderate_skew_explain_20260429_140303.txt` |

Additional EXPLAIN details:

| scenario | scan shape | Bitmap Heap Scan / Recheck Cond | Planning Time | Execution Time | Buffers |
|---|---|---|---:|---:|---|
| B1 | `Index Scan using idx_psd_moderate_skew_active_cat_brand_review` | none observed | `5.827 ms` | `44.722 ms` | `shared hit=6 read=249` |
| B2 | `Index Scan using idx_psd_moderate_skew_active_created` | none observed | `0.172 ms` | `138.563 ms` | `shared hit=16 read=679` |
| B3 | `Index Scan using idx_psd_moderate_skew_active_cat_brand_review` | none observed | `0.256 ms` | `1895.927 ms` | `shared hit=4031 read=12944` |

Do not compare EXPLAIN Execution Time to API p95.

## Table And Index Size

| relation | size |
|---|---:|
| product_search_documents_moderate_skew table | `1601 MB` |
| product_search_documents_moderate_skew indexes | `946 MB` |
| product_search_documents_moderate_skew total | `2547 MB` |
| products_moderate_skew table | `965 MB` |
| product_options_moderate_skew table | `1308 MB` |

## Dataset Fingerprint

| field | value |
|---|---|
| profile | moderate_skew |
| seed version or generation commit hash | Not recorded by existing seed tables |
| products count | `10000000` |
| product_options count | `20500000` |
| read table count | `10000000` |
| min product id | `1` |
| max product id | `10000000` |
| max product updated_at | `2026-04-24 09:12:36.160229` |
| max option updated_at | Not available; source table has no updated_at |
| max source_updated_at | `2026-04-24 09:12:36.160229` |
| max document_refreshed_at | `2026-04-29 03:47:24.757725+00` |
| artifact timestamp | `20260429_124709` |

## Drop / Rebuild Command

Rebuild:

```powershell
.\db\experiments\a1-product-search-denormalized-read-table\run-product-search-documents-moderate-skew.ps1 -Action backfill
```

Drop experiment objects:

```powershell
docker compose exec postgres psql -U readpath -d readpath_lab -c "DROP TABLE IF EXISTS product_search_documents_moderate_skew; DROP FUNCTION IF EXISTS make_product_option_signature(TEXT, TEXT, TEXT);"
```

## Rollback Note

This PR does not modify API behavior, baseline API behavior, DB tuned API behavior, k6 scripts, OpenSearch, Redis, outbox, CDC, or worker code.

Rollback is limited to dropping the read table and helper function above.

## Freshness / Rebuild Limitation

Freshness is rebuild-only.

No trigger, outbox, CDC, relay, worker, queue, API write-path hook, or real-time synchronization is implemented. `document_refreshed_at` identifies rebuild time only.

## Commands Run

Branch setup:

```powershell
git switch main
git pull --ff-only
git switch -c feature/product-search-denormalized-read-table
```

Repository inspection commands were run with `rg`, `Get-Content`, and `docker compose ps`.

Backfill command:

```powershell
.\db\experiments\a1-product-search-denormalized-read-table\run-product-search-documents-moderate-skew.ps1
```

Follow-up spot checks:

```powershell
docker compose exec -T postgres psql -U readpath -d readpath_lab -c "SELECT COUNT(*) AS read_table_count FROM product_search_documents_moderate_skew; SELECT COUNT(*) AS products_without_options FROM products_moderate_skew p LEFT JOIN product_options_moderate_skew po ON po.product_id=p.id WHERE po.product_id IS NULL; SELECT COUNT(*) AS delimiter_collision_count FROM product_options_moderate_skew WHERE color::text LIKE '%|%' OR size::text LIKE '%|%' OR stock_status::text LIKE '%|%';"
```

Section-level validation commands:

```powershell
.\db\experiments\a1-product-search-denormalized-read-table\run-product-search-documents-moderate-skew.ps1 -Action validate-cheap
.\db\experiments\a1-product-search-denormalized-read-table\run-product-search-documents-moderate-skew.ps1 -Action validate-product-id-set
.\db\experiments\a1-product-search-denormalized-read-table\run-product-search-documents-moderate-skew.ps1 -Action validate-equivalence-b1
.\db\experiments\a1-product-search-denormalized-read-table\run-product-search-documents-moderate-skew.ps1 -Action validate-equivalence-b2
.\db\experiments\a1-product-search-denormalized-read-table\run-product-search-documents-moderate-skew.ps1 -Action validate-equivalence-b3
.\db\experiments\a1-product-search-denormalized-read-table\run-product-search-documents-moderate-skew.ps1 -Action validate-signature-count
.\db\experiments\a1-product-search-denormalized-read-table\run-product-search-documents-moderate-skew.ps1 -Action explain
```

## Commands Not Run And Why

Earlier interrupted command:

- The initial monolithic validation SQL was started and canceled because the multi-offset equivalence query was too heavy for this local run.

Intentionally not run:

- `validate-all` was not run.
- multi-offset equivalence

- k6 smoke
- k6 warm-up
- k6 measured run
- API endpoint tests for a denormalized API
- OpenSearch commands
- Redis commands
- outbox/CDC worker commands

Forbidden by PR scope and not run:

- production migration commands

## Exclusions Confirmed

No API endpoint was added.

No k6 benchmark was added or run.

No OpenSearch, Redis, outbox, CDC, relay, worker, or real-time sync mechanism was added.

No uniform or high_skew read table was added.

No Denormalized DB API benchmark p95 or throughput number was added.

No production capacity claim was made.
