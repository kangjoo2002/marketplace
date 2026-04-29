\set ON_ERROR_STOP on
\timing on
\pset pager off
\pset null '[null]'

-- API response field coverage validation for product_search_documents_moderate_skew.
--
-- The denormalized read table must be able to preserve ProductSearchItemResponse
-- in a later API PR without rejoining products_moderate_skew at read time.

SET statement_timeout = '10min';

\echo validate_api_fields_start

DO $$
BEGIN
    IF to_regclass('products_moderate_skew') IS NULL THEN
        RAISE EXCEPTION 'source table does not exist: products_moderate_skew';
    END IF;

    IF to_regclass('product_search_documents_moderate_skew') IS NULL THEN
        RAISE EXCEPTION 'read table does not exist: product_search_documents_moderate_skew';
    END IF;
END $$;

\echo api_response_field_null_counts

SELECT
    COUNT(*) FILTER (WHERE seller_id IS NULL) AS seller_id_null_count,
    COUNT(*) FILTER (WHERE rating IS NULL) AS rating_null_count,
    COUNT(*) FILTER (WHERE updated_at IS NULL) AS updated_at_null_count
FROM product_search_documents_moderate_skew;

\echo api_response_field_mismatch_counts

WITH mismatches AS (
    SELECT
        d.product_id,
        d.seller_id AS read_seller_id,
        p.seller_id AS source_seller_id,
        d.rating AS read_rating,
        p.rating AS source_rating,
        d.updated_at AS read_updated_at,
        p.updated_at AS source_updated_at
    FROM product_search_documents_moderate_skew d
    JOIN products_moderate_skew p
      ON p.id = d.product_id
    WHERE d.seller_id IS DISTINCT FROM p.seller_id
       OR d.rating IS DISTINCT FROM p.rating
       OR d.updated_at IS DISTINCT FROM p.updated_at
)
SELECT
    COUNT(*) FILTER (WHERE read_seller_id IS DISTINCT FROM source_seller_id) AS seller_id_mismatch_count,
    COUNT(*) FILTER (WHERE read_rating IS DISTINCT FROM source_rating) AS rating_mismatch_count,
    COUNT(*) FILTER (WHERE read_updated_at IS DISTINCT FROM source_updated_at) AS updated_at_mismatch_count
FROM mismatches;

\echo api_response_field_mismatch_examples

SELECT
    d.product_id,
    d.seller_id AS read_seller_id,
    p.seller_id AS source_seller_id,
    d.rating AS read_rating,
    p.rating AS source_rating,
    d.updated_at AS read_updated_at,
    p.updated_at AS source_updated_at
FROM product_search_documents_moderate_skew d
JOIN products_moderate_skew p
  ON p.id = d.product_id
WHERE d.seller_id IS DISTINCT FROM p.seller_id
   OR d.rating IS DISTINCT FROM p.rating
   OR d.updated_at IS DISTINCT FROM p.updated_at
LIMIT 50;
