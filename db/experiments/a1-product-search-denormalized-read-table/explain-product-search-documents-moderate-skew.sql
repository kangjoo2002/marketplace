\set ON_ERROR_STOP on
\timing on
\pset pager off

-- EXPLAIN plans for product_search_documents_moderate_skew.
--
-- These PostgreSQL internal execution artifacts are not API p95 latency and
-- must not be compared directly with k6 p95.

\echo explain_start

DO $$
BEGIN
    IF to_regclass('product_search_documents_moderate_skew') IS NULL THEN
        RAISE EXCEPTION 'read table does not exist: product_search_documents_moderate_skew';
    END IF;
END $$;

\echo b1_selective_option_filter_offset_100_review_count_desc

EXPLAIN (ANALYZE, BUFFERS, VERBOSE)
SELECT
    d.product_id,
    d.category_id,
    d.brand_id,
    d.status,
    d.price,
    d.created_at,
    d.review_count
FROM product_search_documents_moderate_skew d
WHERE d.category_id = 75
  AND d.brand_id = 943
  AND d.status = 'ACTIVE'
  AND d.price BETWEEN 10000 AND 100000
  AND d.option_signatures @> ARRAY[
      make_product_option_signature('BLACK', 'M', 'IN_STOCK')
  ]
ORDER BY d.review_count DESC, d.product_id DESC
LIMIT 50 OFFSET 100;

\echo b2_broad_active_option_filter_offset_100_created_at_desc

EXPLAIN (ANALYZE, BUFFERS, VERBOSE)
SELECT
    d.product_id,
    d.category_id,
    d.brand_id,
    d.status,
    d.price,
    d.created_at,
    d.review_count
FROM product_search_documents_moderate_skew d
WHERE d.status = 'ACTIVE'
  AND d.option_signatures @> ARRAY[
      make_product_option_signature('BLACK', 'M', 'IN_STOCK')
  ]
ORDER BY d.created_at DESC, d.product_id DESC
LIMIT 50 OFFSET 100;

\echo b3_deep_offset_option_filter_offset_10000_review_count_desc

EXPLAIN (ANALYZE, BUFFERS, VERBOSE)
SELECT
    d.product_id,
    d.category_id,
    d.brand_id,
    d.status,
    d.price,
    d.created_at,
    d.review_count
FROM product_search_documents_moderate_skew d
WHERE d.category_id = 75
  AND d.brand_id = 943
  AND d.status = 'ACTIVE'
  AND d.price BETWEEN 10000 AND 100000
  AND d.option_signatures @> ARRAY[
      make_product_option_signature('BLACK', 'M', 'IN_STOCK')
  ]
ORDER BY d.review_count DESC, d.product_id DESC
LIMIT 50 OFFSET 10000;
