# A-1 Product Search Denormalized Read Table Observations

## Scope

This document records observations for the PostgreSQL-internal read table:

```text
product_search_documents_moderate_skew
```

Scope is `moderate_skew` only.

The read table was reworked before the API PR so the denormalized DB endpoint can later preserve `ProductSearchItemResponse` without rejoining `products_moderate_skew` at read time.

This PR does not add an API endpoint, k6 benchmark, OpenSearch code, Redis/cache, outbox, CDC, worker, trigger, or real-time synchronization mechanism.

This PR does not claim production-ready denormalization, real-time freshness, API p95 improvement, throughput improvement, OpenSearch replacement, or production capacity.

## API Response Field Coverage

The read table includes the fields needed to map the existing API item shape later:

| read table field | later API field |
|---|---|
| `product_id` | `id` |
| `seller_id` | `sellerId` |
| `category_id` | `categoryId` |
| `brand_id` | `brandId` |
| `status` | `status` |
| `price` | `price` |
| `rating` | `rating` |
| `review_count` | `reviewCount` |
| `created_at` | `createdAt` |
| `updated_at` | `updatedAt` |

Added compatibility fields:

- `seller_id BIGINT NOT NULL`
- `rating NUMERIC(3,2) NOT NULL`
- `updated_at TIMESTAMP NOT NULL`

`updated_at` is copied from `products_moderate_skew.updated_at` for API response compatibility. `source_updated_at` is also copied from `products_moderate_skew.updated_at` because `product_options_moderate_skew` has no `updated_at` column. `document_refreshed_at` records the read-table rebuild time.

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

Separate `colors[]`, `sizes[]`, and `stock_statuses[]` arrays are intentionally not used because they can create false positives when values come from different option rows.

## Products Without Options Policy

Chosen policy: Option A.

The benchmark seed generates at least one option per product, so backfill uses an inner join and expects:

```text
products_without_options = 0
```

This is a benchmark-profile assumption, not a production data model claim.

## Result Files

Old result artifacts from the incomplete read-table schema were removed before the corrected runs. Current successful artifacts:

```text
results/20260429_144356/product_search_documents_moderate_skew_backfill_20260429_144356.txt
results/20260429_144653/product_search_documents_moderate_skew_validate_cheap_20260429_144653.txt
results/20260429_144718/product_search_documents_moderate_skew_validate_product_id_set_20260429_144718.txt
results/20260429_144737/product_search_documents_moderate_skew_validate_api_fields_20260429_144737.txt
results/20260429_144823/product_search_documents_moderate_skew_validate_signature_count_20260429_144823.txt
results/20260429_144928/product_search_documents_moderate_skew_validate_equivalence_b1_20260429_144928.txt
results/20260429_144942/product_search_documents_moderate_skew_validate_equivalence_b2_20260429_144942.txt
results/20260429_144947/product_search_documents_moderate_skew_validate_equivalence_b3_20260429_144947.txt
results/20260429_144957/product_search_documents_moderate_skew_explain_20260429_144957.txt
```

## Backfill Result

| field | value |
|---|---|
| backfill started_at | `2026-04-29 05:44:10.314271+00` |
| backfill finished_at | `2026-04-29 05:46:40.158243+00` |
| backfill duration | `00:02:29.843972` |
| backfilled rows | `10000000` |
| backfill rows/sec | `66736.08` |
| ANALYZE executed_at | `2026-04-29 05:46:39.521126+00` |

## Validation Result

Required section-level validation completed. `validate-all` and multi-offset equivalence were intentionally not run.

| check | result |
|---|---|
| source/read row count match | `true`; products count `10000000`, read table count `10000000` |
| one row per product enforcement | primary key `product_search_documents_moderate_skew_pkey`, `PRIMARY KEY (product_id)` |
| source/read product_id set match | `true`; missing_from_read_count `0`, extra_in_read_count `0` |
| products_without_options | `0` |
| chosen products_without_options policy | Option A |
| option_signatures null count | `0` |
| option_signatures empty count | `0` |
| delimiter collision count | `0` |
| signature_count_mismatch | `0` |
| B1 equivalence | `ids_match = true`, source_page_count `50`, read_page_count `50`, offset `100` |
| B2 equivalence | `ids_match = true`, source_page_count `50`, read_page_count `50`, offset `100` |
| B3 equivalence | `ids_match = true`, source_page_count `50`, read_page_count `50`, offset `10000` |
| validate-all | Not run |
| multi-offset equivalence | Not run |

API response field coverage validation:

| check | value |
|---|---:|
| seller_id_null_count | 0 |
| rating_null_count | 0 |
| updated_at_null_count | 0 |
| seller_id_mismatch_count | 0 |
| rating_mismatch_count | 0 |
| updated_at_mismatch_count | 0 |

The mismatch examples query returned 0 rows.

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

The `validate-cheap` artifact records this as `SQL_SHAPE_ASSERTION` with `verification_type = manual_review_required`. It is a SQL-shape assertion, not a database-executed proof of plan behavior. Plan behavior is recorded in the EXPLAIN summary below.

## EXPLAIN Summary

| scenario | read-time JOIN removed? | read-time EXISTS removed? | option GIN used? | scenario index used? | Sort behavior | residual filter |
|---|---|---|---|---|---|---|
| B1 | yes; no product_options join in the denormalized query or plan | yes; no product_options EXISTS/subplan in the denormalized query or plan | no; option predicate is a residual filter | `idx_psd_moderate_skew_active_cat_brand_review` | no `Sort` node observed; index order satisfies `review_count DESC, product_id DESC` | `price` range and `option_signatures @>` filter; Rows Removed by Filter `94` |
| B2 | yes; no product_options join in the denormalized query or plan | yes; no product_options EXISTS/subplan in the denormalized query or plan | no; option predicate is a residual filter | `idx_psd_moderate_skew_active_created` | no `Sort` node observed; index order satisfies `created_at DESC, product_id DESC` | `option_signatures @>` filter; Rows Removed by Filter `540` |
| B3 | yes; no product_options join in the denormalized query or plan | yes; no product_options EXISTS/subplan in the denormalized query or plan | no; option predicate is a residual filter | `idx_psd_moderate_skew_active_cat_brand_review` | no `Sort` node observed; index order satisfies `review_count DESC, product_id DESC` | `price` range and `option_signatures @>` filter; Rows Removed by Filter `6820` |

Additional EXPLAIN details:

| scenario | scan shape | Bitmap Heap Scan / Recheck Cond | Planning Time | Execution Time | Buffers |
|---|---|---|---:|---:|---|
| B1 | `Index Scan using idx_psd_moderate_skew_active_cat_brand_review` | none observed | `1.449 ms` | `1.791 ms` | `shared hit=6 read=249` |
| B2 | `Index Scan using idx_psd_moderate_skew_active_created` | none observed | `0.297 ms` | `6.471 ms` | `shared hit=14 read=681` |
| B3 | `Index Scan using idx_psd_moderate_skew_active_cat_brand_review` | none observed | `1.963 ms` | `96.187 ms` | `shared hit=280 read=16695` |

Do not compare EXPLAIN Execution Time to API p95.

## Table And Index Size

| relation | size |
|---|---:|
| product_search_documents_moderate_skew table | `1832 MB` |
| product_search_documents_moderate_skew indexes | `946 MB` |
| product_search_documents_moderate_skew total | `2779 MB` |
| products_moderate_skew table | `965 MB` |
| product_options_moderate_skew table | `1308 MB` |

## Dataset Fingerprint

| field | value |
|---|---|
| profile | moderate_skew |
| products count | `10000000` |
| product_options count | `20500000` |
| read table count | `10000000` |
| min product id | `1` |
| max product id | `10000000` |
| max product updated_at | `2026-04-24 09:12:36.160229` |
| max option updated_at | Not available; source table has no updated_at |
| max read updated_at | `2026-04-24 09:12:36.160229` |
| max source_updated_at | `2026-04-24 09:12:36.160229` |
| max document_refreshed_at | `2026-04-29 05:44:10.344209+00` |

## Freshness / Rebuild Limitation

Freshness is rebuild-only.

No trigger, outbox, CDC, relay, worker, queue, API write-path hook, or real-time synchronization is implemented. `document_refreshed_at` identifies rebuild time only.

## Commands Run

Git recovery:

```powershell
git branch --show-current
git status --short
git log --oneline --decorate --graph -n 20
git branch --all --verbose
git remote -v
git pull --ff-only
git show --no-patch --pretty=fuller ea00f83
git reset --hard 3607df1
git push --force-with-lease origin main
git switch feature/product-search-denormalized-read-table
```

Artifact cleanup:

```powershell
Remove-Item ...\db\experiments\a1-product-search-denormalized-read-table\results\<old timestamp dirs> -Recurse -Force
```

Section-level DB actions:

```powershell
.\db\experiments\a1-product-search-denormalized-read-table\run-product-search-documents-moderate-skew.ps1 -Action backfill
.\db\experiments\a1-product-search-denormalized-read-table\run-product-search-documents-moderate-skew.ps1 -Action validate-cheap
.\db\experiments\a1-product-search-denormalized-read-table\run-product-search-documents-moderate-skew.ps1 -Action validate-product-id-set
.\db\experiments\a1-product-search-denormalized-read-table\run-product-search-documents-moderate-skew.ps1 -Action validate-api-fields
.\db\experiments\a1-product-search-denormalized-read-table\run-product-search-documents-moderate-skew.ps1 -Action validate-signature-count
.\db\experiments\a1-product-search-denormalized-read-table\run-product-search-documents-moderate-skew.ps1 -Action validate-equivalence-b1
.\db\experiments\a1-product-search-denormalized-read-table\run-product-search-documents-moderate-skew.ps1 -Action validate-equivalence-b2
.\db\experiments\a1-product-search-denormalized-read-table\run-product-search-documents-moderate-skew.ps1 -Action validate-equivalence-b3
.\db\experiments\a1-product-search-denormalized-read-table\run-product-search-documents-moderate-skew.ps1 -Action explain
```

## Commands Not Run

- `validate-all`
- multi-offset equivalence
- k6 smoke
- k6 warm-up
- k6 measured run
- API endpoint tests for a denormalized API
- OpenSearch commands
- Redis commands
- outbox/CDC/worker commands
- production migration commands

## Exclusions Confirmed

No API endpoint was added.

No controller, service, repository, request DTO, response DTO, or page/item response class was modified.

No k6 benchmark was added or run.

No OpenSearch, Redis, outbox, CDC, relay, worker, trigger, or real-time sync mechanism was added.

No uniform or high_skew read table was added.

No Denormalized DB API benchmark p95 or throughput number was added.

No production capacity claim was made.
