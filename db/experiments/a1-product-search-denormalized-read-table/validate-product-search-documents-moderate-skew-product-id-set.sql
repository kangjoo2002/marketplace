\set ON_ERROR_STOP on
\timing on
\pset pager off
\pset null '[null]'

-- Product-id set validation section.
-- Computes missing/extra product ids once into temporary tables, then reuses
-- those tables for examples and summary counts.

SET statement_timeout = '10min';

\echo validate_product_id_set_start

DO $$
BEGIN
    IF to_regclass('products_moderate_skew') IS NULL THEN
        RAISE EXCEPTION 'source table does not exist: products_moderate_skew';
    END IF;

    IF to_regclass('product_search_documents_moderate_skew') IS NULL THEN
        RAISE EXCEPTION 'read table does not exist: product_search_documents_moderate_skew';
    END IF;
END $$;

\echo source_has_product_but_read_table_does_not

DROP TABLE IF EXISTS pg_temp.psd_moderate_skew_missing_from_read;
CREATE TEMP TABLE psd_moderate_skew_missing_from_read AS
SELECT p.id
FROM products_moderate_skew p
LEFT JOIN product_search_documents_moderate_skew d
  ON d.product_id = p.id
WHERE d.product_id IS NULL;

SELECT id
FROM psd_moderate_skew_missing_from_read
ORDER BY id
LIMIT 50;

\echo read_table_has_product_but_source_does_not

DROP TABLE IF EXISTS pg_temp.psd_moderate_skew_extra_in_read;
CREATE TEMP TABLE psd_moderate_skew_extra_in_read AS
SELECT d.product_id
FROM product_search_documents_moderate_skew d
LEFT JOIN products_moderate_skew p
  ON p.id = d.product_id
WHERE p.id IS NULL;

SELECT product_id
FROM psd_moderate_skew_extra_in_read
ORDER BY product_id
LIMIT 50;

\echo source_read_product_id_set_match

SELECT
    (SELECT COUNT(*) FROM psd_moderate_skew_missing_from_read) AS missing_from_read_count,
    (SELECT COUNT(*) FROM psd_moderate_skew_extra_in_read) AS extra_in_read_count,
    (SELECT COUNT(*) FROM psd_moderate_skew_missing_from_read) = 0
        AND (SELECT COUNT(*) FROM psd_moderate_skew_extra_in_read) = 0 AS product_id_set_match;
