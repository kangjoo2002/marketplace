# A-1 Product Search Denormalized Read Table

## Purpose

This experiment validates a PostgreSQL-internal denormalized read table for the `moderate_skew` product-search benchmark profile.

The read table is:

```text
product_search_documents_moderate_skew
```

The target question is whether the search read path can remove read-time `products_moderate_skew` + `product_options_moderate_skew` `JOIN`/`EXISTS` dependency while preserving result equivalence with the normalized DB tuned source query.

DB tuned API already represents what can be achieved inside the normalized PostgreSQL path using selected indexes + `EXISTS` rewrite. Denormalized DB is not a rescue step because DB tuned API failed. It is a read-model validation step that checks whether read-time `JOIN`/`EXISTS` dependency and query/index coupling can be reduced before moving to OpenSearch.

OpenSearch is a later stage.

## PR Scope

This PR is moderate_skew-only and creates DB-level experiment artifacts:

- read table schema
- helper signature function
- backfill SQL
- candidate read-table indexes
- validation SQL
- denormalized EXPLAIN SQL
- PowerShell runner
- observations document

This PR does not add an API endpoint, k6 benchmark, OpenSearch code, Redis/cache, outbox, CDC, worker, or real-time synchronization mechanism.

This PR does not claim production-ready denormalization or real-time freshness.
It validates a PostgreSQL-internal read model for the moderate_skew benchmark profile only.

The success criteria are result equivalence with the normalized source query,
removal of read-time JOIN/EXISTS from the search path, documented query-plan behavior,
and documented rebuild/freshness/rollback limitations.

Sort elimination and p95 improvement are expected outcomes to observe, not required success criteria.

## Source And Target Tables

Source:

```text
products_moderate_skew
product_options_moderate_skew
```

Target:

```text
product_search_documents_moderate_skew
```

The read table stores one row per product and enforces that with:

```sql
PRIMARY KEY (product_id)
```

Minimum read-table columns:

- `product_id`
- `category_id`
- `brand_id`
- `status`
- `price`
- `created_at`
- `review_count`
- `option_signatures`
- `source_updated_at`
- `document_refreshed_at`

Repository schema adaptation:

- `product_options_moderate_skew` does not have `updated_at`.
- `source_updated_at` is populated from `products_moderate_skew.updated_at`.
- Dataset fingerprint SQL records `max_option_updated_at` as `NULL` with a note.

## Option Signature Model

The read table uses:

```sql
option_signatures TEXT[] NOT NULL
```

It intentionally does not store separate `colors[]`, `sizes[]`, and `stock_statuses[]` filter arrays. The option predicate requires `color`, `size`, and `stock_status` to exist on the same option row. Separate arrays can create false positives when values come from different option rows.

Signature format:

```text
{color}|{size}|{stock_status}
```

Example:

```text
BLACK|M|IN_STOCK
```

The helper function is:

```sql
make_product_option_signature(color TEXT, size TEXT, stock_status TEXT)
```

Backfill and denormalized read/equivalence queries use `make_product_option_signature(...)` to build the stored and searched signature value.

`validate-signature-count` compares source distinct option combinations with read-table `option_signatures` cardinality using tuple-based distinct counting:

```sql
COUNT(DISTINCT (po.color, po.size, po.stock_status))
```

This keeps the validation meaning unchanged while avoiding per-row signature string construction in the 20.5M-row option table. Delimiter encoding safety is checked separately by `validate-cheap`.

Delimiter assumption:

- The delimiter is `|`.
- Source option values must not contain `|`.
- The validation SQL checks delimiter collisions with `LIKE '%|%'`.

## Products Without Options Policy

Chosen policy: Option A.

The benchmark seed logic generates at least one option row per product. The backfill uses an inner join from `products_moderate_skew` to `product_options_moderate_skew`.

This is a benchmark-profile assumption, not a production claim. Validation records `products_without_options`; the expected result for this policy is `0`.

If `products_without_options` is non-zero, row-count and product-id set validation should fail and the read model policy must be revisited before using the artifact.

## Candidate Indexes

B1/B3 candidate:

```sql
CREATE INDEX idx_psd_moderate_skew_active_cat_brand_review
ON product_search_documents_moderate_skew(
    category_id,
    brand_id,
    review_count DESC,
    product_id DESC
)
WHERE status = 'ACTIVE';
```

B2 candidate:

```sql
CREATE INDEX idx_psd_moderate_skew_active_created
ON product_search_documents_moderate_skew(
    created_at DESC,
    product_id DESC
)
WHERE status = 'ACTIVE';
```

Option filter candidate:

```sql
CREATE INDEX idx_psd_moderate_skew_option_signatures_gin
ON product_search_documents_moderate_skew
USING GIN(option_signatures);
```

These are validation candidates only. They do not guarantee Sort removal.

## B1/B2/B3 Parameters

The validation SQL uses the current B1/B2/B3 constants from the repository k6 product-search scripts:

| scenario | product filters | option filter | sort | workload offset |
|---|---|---|---|---:|
| B1 selective option filter | `category_id=75`, `brand_id=943`, `status=ACTIVE`, `price BETWEEN 10000 AND 100000` | `BLACK|M|IN_STOCK` | `review_count DESC, product_id DESC` | 100 |
| B2 broad active option filter | `status=ACTIVE` | `BLACK|M|IN_STOCK` | `created_at DESC, product_id DESC` | 100 |
| B3 selective deep OFFSET | `category_id=75`, `brand_id=943`, `status=ACTIVE`, `price BETWEEN 10000 AND 100000` | `BLACK|M|IN_STOCK` | `review_count DESC, product_id DESC` | 10000 |

Validation checks the required representative offsets:

```text
B1 offset 100
B2 offset 100
B3 offset 10000
```

Optional multi-offset validation is not part of the default local validation script.

Every comparison uses deterministic ordering:

- `ORDER BY review_count DESC, product_id DESC`
- `ORDER BY created_at DESC, product_id DESC`

## Backfill Procedure

Start PostgreSQL:

```powershell
docker compose up -d
```

Run schema, backfill, indexes, and analyze:

```powershell
.\db\experiments\a1-product-search-denormalized-read-table\run-product-search-documents-moderate-skew.ps1
```

Backfill only:

```powershell
.\db\experiments\a1-product-search-denormalized-read-table\run-product-search-documents-moderate-skew.ps1 -Action backfill
```

The backfill script:

1. Creates or replaces `make_product_option_signature`.
2. Creates `product_search_documents_moderate_skew` if missing.
3. Checks delimiter collisions.
4. Checks products without options.
5. Drops candidate read-table indexes before rebuild.
6. Truncates the read table.
7. Inserts one row per product using `array_agg(DISTINCT option_signature)`.
8. Recreates candidate indexes.
9. Runs `ANALYZE product_search_documents_moderate_skew`.
10. Records timing, sizes, index definitions, and dataset fingerprint output.

## Validation Procedure

Validation is split into section-level actions. Run only the section you intend to validate:

```powershell
.\db\experiments\a1-product-search-denormalized-read-table\run-product-search-documents-moderate-skew.ps1 -Action validate-cheap
.\db\experiments\a1-product-search-denormalized-read-table\run-product-search-documents-moderate-skew.ps1 -Action validate-product-id-set
.\db\experiments\a1-product-search-denormalized-read-table\run-product-search-documents-moderate-skew.ps1 -Action validate-signature-count
.\db\experiments\a1-product-search-denormalized-read-table\run-product-search-documents-moderate-skew.ps1 -Action validate-equivalence-b1
.\db\experiments\a1-product-search-denormalized-read-table\run-product-search-documents-moderate-skew.ps1 -Action validate-equivalence-b2
.\db\experiments\a1-product-search-denormalized-read-table\run-product-search-documents-moderate-skew.ps1 -Action validate-equivalence-b3
```

Run all validation sections only when explicitly intended:

```powershell
.\db\experiments\a1-product-search-denormalized-read-table\run-product-search-documents-moderate-skew.ps1 -Action validate-all
```

The runner default remains `backfill`. `validate-all` is not the default and does not run unless explicitly requested.

Each validation SQL section sets `statement_timeout = '10min'` to prevent another indefinite local run. Validation still performs full-table integrity checks against the 10M products and 20.5M options benchmark dataset, so some sections may be expensive. The `validate-signature-count` action is expected to be the heaviest because it groups the 20.5M-row `product_options_moderate_skew` table by `product_id`.

Validation checks:

| action | checks |
|---|---|
| `validate-cheap` | source/read row count, primary-key one-row-per-product enforcement, products without options, `option_signatures` null/empty count, delimiter collision count, table/index sizes, dataset fingerprint, `ANALYZE` status, SQL-shape assertion requiring manual review |
| `validate-product-id-set` | source/read product-id missing/extra examples and summary counts |
| `validate-signature-count` | source distinct option combination count vs read-table signature count |
| `validate-equivalence-b1` | B1 page ID equivalence at offset `100` |
| `validate-equivalence-b2` | B2 page ID equivalence at offset `100` |
| `validate-equivalence-b3` | B3 page ID equivalence at offset `10000` |
| `validate-all` | runs all validation sections above; explicit only |

The query-shape assertion is a SQL-shape statement for manual review. It is not a DB-executed proof that PostgreSQL removed a join or subquery from a plan.

## EXPLAIN Procedure

EXPLAIN only:

```powershell
.\db\experiments\a1-product-search-denormalized-read-table\run-product-search-documents-moderate-skew.ps1 -Action explain
```

The EXPLAIN script runs:

```sql
EXPLAIN (ANALYZE, BUFFERS, VERBOSE)
```

for B1, B2, and B3 denormalized read-table queries.

Interpretation must document:

- read-time `JOIN` removed?
- read-time `EXISTS` removed?
- `option_signatures` GIN index used?
- B1/B3 review index used?
- B2 active-created index used?
- Sort removed or still present?
- residual filter present?
- Bitmap Heap Scan / Recheck Cond?
- Rows Removed by Filter?
- Planning Time
- Execution Time
- Buffers

`EXPLAIN` Execution Time is a PostgreSQL internal execution artifact. Do not interpret it as API p95 latency. Do not compare it directly against k6 p95.

## Result Artifacts

The runner writes successful outputs under:

```text
db/experiments/a1-product-search-denormalized-read-table/results/<YYYYMMDD_HHMMSS>/
```

Possible files:

```text
product_search_documents_moderate_skew_backfill_<timestamp>.txt
product_search_documents_moderate_skew_validate_cheap_<timestamp>.txt
product_search_documents_moderate_skew_validate_product_id_set_<timestamp>.txt
product_search_documents_moderate_skew_validate_signature_count_<timestamp>.txt
product_search_documents_moderate_skew_validate_equivalence_b1_<timestamp>.txt
product_search_documents_moderate_skew_validate_equivalence_b2_<timestamp>.txt
product_search_documents_moderate_skew_validate_equivalence_b3_<timestamp>.txt
product_search_documents_moderate_skew_explain_<timestamp>.txt
```

No k6 summary JSON, API benchmark result, OpenSearch result, Redis/cache result, or production monitoring artifact belongs in this directory.

## Drop / Rebuild / Rollback

Rebuild the experiment read table:

```powershell
.\db\experiments\a1-product-search-denormalized-read-table\run-product-search-documents-moderate-skew.ps1 -Action backfill
```

Drop the read-table experiment objects:

```powershell
docker compose exec postgres psql -U readpath -d readpath_lab -c "DROP TABLE IF EXISTS product_search_documents_moderate_skew; DROP FUNCTION IF EXISTS make_product_option_signature(TEXT, TEXT, TEXT);"
```

Rollback note:

- This experiment does not modify existing API behavior.
- Existing normalized product search remains on `products_moderate_skew` and `product_options_moderate_skew`.
- Removing the read table and helper function rolls back this experiment's DB objects.

## Freshness Limitation

Freshness is rebuild-only in this PR.

There is no trigger, outbox, CDC, relay, worker, queue, API write-path hook, or real-time synchronization. `document_refreshed_at` records when the document row was rebuilt, not an automatically maintained freshness guarantee.

## What Not To Conclude

Do not conclude:

- production-ready denormalization
- production capacity
- API p95 improvement
- Sort removal as required success
- OpenSearch replacement
- real-time freshness
- final production index choice

OpenSearch remains a later stage.

## Next Step

After reviewing the validation and EXPLAIN artifacts, summarize whether B1/B2/B3 page IDs match and how the read-table plans behave. Use that to decide whether a denormalized DB API benchmark PR is worth adding later, without changing this PR's scope.
