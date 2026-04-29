\set ON_ERROR_STOP on
\timing on
\pset pager off
\pset null '[null]'

-- B1 required-offset result equivalence validation.

SET statement_timeout = '10min';

\echo validate_equivalence_b1_start

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

\echo b1_required_offset_100_equivalence

WITH source_page AS (
    SELECT ARRAY(
        SELECT p.id
        FROM products_moderate_skew p
        WHERE p.category_id = 75
          AND p.brand_id = 943
          AND p.status = 'ACTIVE'
          AND p.price BETWEEN 10000 AND 100000
          AND EXISTS (
              SELECT 1
              FROM product_options_moderate_skew po
              WHERE po.product_id = p.id
                AND po.color = 'BLACK'
                AND po.size = 'M'
                AND po.stock_status = 'IN_STOCK'
          )
        ORDER BY p.review_count DESC, p.id DESC
        LIMIT 50 OFFSET 100
    ) AS source_ids
),
read_page AS (
    SELECT ARRAY(
        SELECT d.product_id
        FROM product_search_documents_moderate_skew d
        WHERE d.category_id = 75
          AND d.brand_id = 943
          AND d.status = 'ACTIVE'
          AND d.price BETWEEN 10000 AND 100000
          AND d.option_signatures @> ARRAY[
              make_product_option_signature('BLACK', 'M', 'IN_STOCK')
          ]
        ORDER BY d.review_count DESC, d.product_id DESC
        LIMIT 50 OFFSET 100
    ) AS read_ids
)
SELECT
    'B1_selective_option_filter' AS scenario,
    100 AS offset_rows,
    cardinality(sp.source_ids) AS source_page_count,
    cardinality(rp.read_ids) AS read_page_count,
    sp.source_ids = rp.read_ids AS ids_match,
    CASE
        WHEN sp.source_ids = rp.read_ids THEN NULL::BIGINT
        ELSE (
            SELECT source_id
            FROM unnest(sp.source_ids) WITH ORDINALITY AS s(source_id, ord)
            FULL JOIN unnest(rp.read_ids) WITH ORDINALITY AS r(read_id, ord)
              USING (ord)
            WHERE s.source_id IS DISTINCT FROM r.read_id
            ORDER BY ord
            LIMIT 1
        )
    END AS first_mismatched_source_id,
    CASE
        WHEN sp.source_ids = rp.read_ids THEN NULL::BIGINT
        ELSE (
            SELECT read_id
            FROM unnest(sp.source_ids) WITH ORDINALITY AS s(source_id, ord)
            FULL JOIN unnest(rp.read_ids) WITH ORDINALITY AS r(read_id, ord)
              USING (ord)
            WHERE s.source_id IS DISTINCT FROM r.read_id
            ORDER BY ord
            LIMIT 1
        )
    END AS first_mismatched_read_id
FROM source_page sp
CROSS JOIN read_page rp;
