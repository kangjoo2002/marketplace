\set ON_ERROR_STOP on
\timing on
\pset pager off

-- A-1 Product Search Denormalized DB read table.
--
-- Scope:
--   products_moderate_skew
--   product_options_moderate_skew
--   product_search_documents_moderate_skew
--
-- This script creates and rebuilds a PostgreSQL-internal read table for the
-- moderate_skew benchmark profile only. It intentionally does not add API
-- endpoints, k6 benchmarks, OpenSearch, Redis, outbox, CDC, or real-time sync.

\echo experiment_start

DO $$
BEGIN
    IF to_regclass('products_moderate_skew') IS NULL THEN
        RAISE EXCEPTION 'source table does not exist: products_moderate_skew';
    END IF;

    IF to_regclass('product_options_moderate_skew') IS NULL THEN
        RAISE EXCEPTION 'source table does not exist: product_options_moderate_skew';
    END IF;
END $$;

\echo source_schema_adaptation

SELECT
    'product_options_moderate_skew has no updated_at column in this repository; source_updated_at uses products_moderate_skew.updated_at only.' AS note;

\echo helper_function

CREATE OR REPLACE FUNCTION make_product_option_signature(
    color TEXT,
    size TEXT,
    stock_status TEXT
)
RETURNS TEXT
LANGUAGE sql
IMMUTABLE
STRICT
AS $$
    SELECT color || '|' || size || '|' || stock_status;
$$;

\echo read_table_schema

CREATE TABLE IF NOT EXISTS product_search_documents_moderate_skew (
    product_id BIGINT PRIMARY KEY,
    category_id BIGINT NOT NULL,
    brand_id BIGINT NOT NULL,
    status VARCHAR(20) NOT NULL,
    price INTEGER NOT NULL,
    created_at TIMESTAMP NOT NULL,
    review_count INTEGER NOT NULL,
    option_signatures TEXT[] NOT NULL,
    source_updated_at TIMESTAMP NOT NULL,
    document_refreshed_at TIMESTAMPTZ NOT NULL
);

\echo pre_backfill_validation

SELECT COUNT(*) AS delimiter_collision_count
FROM product_options_moderate_skew
WHERE color::TEXT LIKE '%|%'
   OR size::TEXT LIKE '%|%'
   OR stock_status::TEXT LIKE '%|%';

SELECT COUNT(*) AS products_without_options
FROM products_moderate_skew p
LEFT JOIN product_options_moderate_skew po
  ON po.product_id = p.id
WHERE po.product_id IS NULL;

\echo drop_candidate_indexes_before_rebuild

DROP INDEX IF EXISTS idx_psd_moderate_skew_active_cat_brand_review;
DROP INDEX IF EXISTS idx_psd_moderate_skew_active_created;
DROP INDEX IF EXISTS idx_psd_moderate_skew_option_signatures_gin;

\echo backfill_start

DROP TABLE IF EXISTS pg_temp.psd_moderate_skew_backfill_run;
CREATE TEMP TABLE psd_moderate_skew_backfill_run AS
SELECT clock_timestamp() AS started_at;

TRUNCATE TABLE product_search_documents_moderate_skew;

INSERT INTO product_search_documents_moderate_skew (
    product_id,
    category_id,
    brand_id,
    status,
    price,
    created_at,
    review_count,
    option_signatures,
    source_updated_at,
    document_refreshed_at
)
SELECT
    p.id AS product_id,
    p.category_id,
    p.brand_id,
    p.status,
    p.price,
    p.created_at,
    p.review_count,
    array_agg(DISTINCT sig.option_signature ORDER BY sig.option_signature) AS option_signatures,
    p.updated_at AS source_updated_at,
    now() AS document_refreshed_at
FROM products_moderate_skew p
JOIN product_options_moderate_skew po
  ON po.product_id = p.id
CROSS JOIN LATERAL (
    SELECT make_product_option_signature(
        po.color::TEXT,
        po.size::TEXT,
        po.stock_status::TEXT
    ) AS option_signature
) sig
WHERE po.color IS NOT NULL
  AND po.size IS NOT NULL
  AND po.stock_status IS NOT NULL
GROUP BY
    p.id,
    p.category_id,
    p.brand_id,
    p.status,
    p.price,
    p.created_at,
    p.review_count,
    p.updated_at;

\echo candidate_indexes

CREATE INDEX idx_psd_moderate_skew_active_cat_brand_review
ON product_search_documents_moderate_skew(
    category_id,
    brand_id,
    review_count DESC,
    product_id DESC
)
WHERE status = 'ACTIVE';

CREATE INDEX idx_psd_moderate_skew_active_created
ON product_search_documents_moderate_skew(
    created_at DESC,
    product_id DESC
)
WHERE status = 'ACTIVE';

CREATE INDEX idx_psd_moderate_skew_option_signatures_gin
ON product_search_documents_moderate_skew
USING GIN(option_signatures);

\echo analyze_read_table

ANALYZE product_search_documents_moderate_skew;

\echo backfill_summary

WITH elapsed AS (
    SELECT
        started_at,
        clock_timestamp() AS finished_at
    FROM psd_moderate_skew_backfill_run
),
counts AS (
    SELECT COUNT(*) AS backfilled_rows
    FROM product_search_documents_moderate_skew
)
SELECT
    e.started_at AS backfill_started_at,
    e.finished_at AS backfill_finished_at,
    e.finished_at - e.started_at AS backfill_duration,
    c.backfilled_rows,
    ROUND(
        c.backfilled_rows::NUMERIC / NULLIF(EXTRACT(EPOCH FROM e.finished_at - e.started_at), 0),
        2
    ) AS backfill_rows_per_sec
FROM elapsed e
CROSS JOIN counts c;

\echo analyze_status

SELECT
    relname,
    last_analyze,
    last_autoanalyze
FROM pg_stat_all_tables
WHERE schemaname = 'public'
  AND relname = 'product_search_documents_moderate_skew';

\echo size_summary

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

\echo index_definitions

SELECT
    schemaname,
    tablename,
    indexname,
    indexdef
FROM pg_indexes
WHERE schemaname = 'public'
  AND tablename = 'product_search_documents_moderate_skew'
ORDER BY indexname;
