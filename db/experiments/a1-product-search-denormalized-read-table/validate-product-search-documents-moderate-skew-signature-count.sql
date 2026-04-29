\set ON_ERROR_STOP on
\timing on
\pset pager off
\pset null '[null]'

-- Signature-count validation section.
-- This is expected to be the heaviest validation section because it groups
-- product_options_moderate_skew by product_id across the 20.5M-row option table.

SET statement_timeout = '10min';

-- Local to this psql session. Intended to give the GROUP BY / DISTINCT
-- validation section enough memory without changing global database settings.
SET work_mem = '256MB';

\echo validate_signature_count_start

DO $$
BEGIN
    IF to_regclass('product_options_moderate_skew') IS NULL THEN
        RAISE EXCEPTION 'source table does not exist: product_options_moderate_skew';
    END IF;

    IF to_regclass('product_search_documents_moderate_skew') IS NULL THEN
        RAISE EXCEPTION 'read table does not exist: product_search_documents_moderate_skew';
    END IF;
END $$;

\echo signature_count_mismatch_examples

DROP TABLE IF EXISTS pg_temp.psd_moderate_skew_signature_count_mismatch;
CREATE TEMP TABLE psd_moderate_skew_signature_count_mismatch AS
WITH source_signature_counts AS (
    SELECT
        po.product_id,
        COUNT(DISTINCT (po.color, po.size, po.stock_status)) AS source_signature_count
    FROM product_options_moderate_skew po
    WHERE po.color IS NOT NULL
      AND po.size IS NOT NULL
      AND po.stock_status IS NOT NULL
    GROUP BY po.product_id
),
read_signature_counts AS (
    SELECT
        product_id,
        cardinality(option_signatures) AS read_signature_count
    FROM product_search_documents_moderate_skew
)
SELECT
    s.product_id,
    s.source_signature_count,
    r.read_signature_count
FROM source_signature_counts s
JOIN read_signature_counts r
  ON r.product_id = s.product_id
WHERE s.source_signature_count <> r.read_signature_count;

SELECT
    product_id,
    source_signature_count,
    read_signature_count
FROM psd_moderate_skew_signature_count_mismatch
LIMIT 50;

\echo signature_count_mismatch_summary

SELECT COUNT(*) AS signature_count_mismatch
FROM psd_moderate_skew_signature_count_mismatch;
