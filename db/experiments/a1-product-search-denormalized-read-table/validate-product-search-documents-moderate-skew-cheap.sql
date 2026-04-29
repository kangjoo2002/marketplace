\set ON_ERROR_STOP on
\timing on
\pset pager off
\pset null '[null]'

-- Cheap validation section for product_search_documents_moderate_skew.
-- This section avoids the product_id set diff, signature count mismatch, and
-- B1/B2/B3 page equivalence checks. It still scans benchmark-sized tables for
-- counts and delimiter checks, so it is not a micro-check.

SET statement_timeout = '10min';

\echo validate_cheap_start

DO $$
BEGIN
    IF to_regclass('products_moderate_skew') IS NULL THEN
        RAISE EXCEPTION 'source table does not exist: products_moderate_skew';
    END IF;

    IF to_regclass('product_options_moderate_skew') IS NULL THEN
        RAISE EXCEPTION 'source table does not exist: product_options_moderate_skew';
    END IF;

    IF to_regclass('product_search_documents_moderate_skew') IS NULL THEN
        RAISE EXCEPTION 'read table does not exist: product_search_documents_moderate_skew';
    END IF;
END $$;

\echo query_shape_assertion

SELECT
    'SQL_SHAPE_ASSERTION' AS check_type,
    'manual_review_required' AS verification_type,
    'Denormalized read queries in this validation file read product_search_documents_moderate_skew and do not include product_options JOIN/EXISTS in the read-table query shape.' AS note;

\echo source_read_row_count_match

SELECT
    p.source_product_count,
    d.read_table_count,
    p.source_product_count = d.read_table_count AS row_count_match
FROM (SELECT COUNT(*) AS source_product_count FROM products_moderate_skew) p
CROSS JOIN (SELECT COUNT(*) AS read_table_count FROM product_search_documents_moderate_skew) d;

\echo primary_key_one_row_per_product_enforcement

SELECT
    conname,
    contype,
    pg_get_constraintdef(oid) AS constraint_definition
FROM pg_constraint
WHERE conrelid = 'product_search_documents_moderate_skew'::REGCLASS
  AND contype = 'p'
ORDER BY conname;

\echo products_without_options_policy_check

SELECT COUNT(*) AS products_without_options
FROM products_moderate_skew p
LEFT JOIN product_options_moderate_skew po
  ON po.product_id = p.id
WHERE po.product_id IS NULL;

SELECT
    'Option A' AS chosen_policy,
    'Backfill uses INNER JOIN. This benchmark-profile policy is valid when products_without_options = 0.' AS policy_note;

\echo option_signature_integrity

SELECT
    COUNT(*) FILTER (WHERE option_signatures IS NULL) AS option_signatures_null_count,
    COUNT(*) FILTER (WHERE cardinality(option_signatures) = 0) AS option_signatures_empty_count
FROM product_search_documents_moderate_skew;

\echo delimiter_collision_validation

SELECT COUNT(*) AS delimiter_collision_count
FROM product_options_moderate_skew
WHERE color::TEXT LIKE '%|%'
   OR size::TEXT LIKE '%|%'
   OR stock_status::TEXT LIKE '%|%';

\echo table_index_sizes

SELECT pg_size_pretty(pg_relation_size('product_search_documents_moderate_skew')) AS table_size;
SELECT pg_size_pretty(pg_indexes_size('product_search_documents_moderate_skew')) AS indexes_size;
SELECT pg_size_pretty(pg_total_relation_size('product_search_documents_moderate_skew')) AS total_size;
SELECT pg_size_pretty(pg_relation_size('products_moderate_skew')) AS products_moderate_skew_table_size;
SELECT pg_size_pretty(pg_relation_size('product_options_moderate_skew')) AS product_options_moderate_skew_table_size;

\echo dataset_fingerprint

SELECT
    'moderate_skew' AS profile,
    COUNT(*) AS products_count,
    MIN(id) AS min_product_id,
    MAX(id) AS max_product_id,
    MAX(updated_at) AS max_product_updated_at
FROM products_moderate_skew;

SELECT
    'moderate_skew' AS profile,
    COUNT(*) AS options_count,
    MIN(product_id) AS min_option_product_id,
    MAX(product_id) AS max_option_product_id,
    NULL::TIMESTAMP AS max_option_updated_at,
    'product_options_moderate_skew has no updated_at column' AS max_option_updated_at_note
FROM product_options_moderate_skew;

SELECT
    'moderate_skew' AS profile,
    COUNT(*) AS read_table_count,
    MIN(product_id) AS min_read_product_id,
    MAX(product_id) AS max_read_product_id,
    MAX(source_updated_at) AS max_source_updated_at,
    MAX(document_refreshed_at) AS max_document_refreshed_at
FROM product_search_documents_moderate_skew;

\echo analyze_status

SELECT
    relname,
    last_analyze,
    last_autoanalyze
FROM pg_stat_all_tables
WHERE schemaname = 'public'
  AND relname IN (
      'products_moderate_skew',
      'product_options_moderate_skew',
      'product_search_documents_moderate_skew'
  )
ORDER BY relname;
