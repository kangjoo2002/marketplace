\set ON_ERROR_STOP on
\timing on
\pset pager off

-- A-1a products-only pre-index-tuning baseline EXPLAIN.
--
-- Supported psql variable:
--   -v target_table=products_uniform
--   -v target_table=products_moderate_skew
--   -v target_table=products_high_skew
--   -v target_table=products_active
--
-- If target_table is omitted, products_active is used.
-- Parameter values are synthetic/local benchmark parameters derived from the
-- deterministic seed profile and distribution verification artifacts. They are
-- not production-derived values.

\if :{?target_table}
\else
\set target_table 'products_active'
\endif

CREATE TEMP TABLE products_baseline_explain_config (
    target_table TEXT NOT NULL
);

INSERT INTO products_baseline_explain_config (target_table)
VALUES (:'target_table');

DO $$
DECLARE
    selected_target_table TEXT;
BEGIN
    SELECT target_table
    INTO selected_target_table
    FROM products_baseline_explain_config;

    IF selected_target_table NOT IN (
        'products_uniform',
        'products_moderate_skew',
        'products_high_skew',
        'products_active'
    ) THEN
        RAISE EXCEPTION
            'Unsupported target_table: %. Supported values: products_uniform, products_moderate_skew, products_high_skew, products_active',
            selected_target_table;
    END IF;

    IF to_regclass(selected_target_table) IS NULL THEN
        RAISE EXCEPTION 'target_table does not exist: %', selected_target_table;
    END IF;
END $$;

SELECT :'target_table' AS target_table, COUNT(*) AS product_count
FROM :target_table;

\echo
\echo Q1_category_status_price_created_at_shallow
EXPLAIN (ANALYZE, BUFFERS, VERBOSE)
SELECT
    id,
    seller_id,
    category_id,
    brand_id,
    status,
    price,
    rating,
    review_count,
    created_at,
    updated_at
FROM :target_table
WHERE category_id = 35
  AND status = 'ACTIVE'
  AND price BETWEEN 10000 AND 100000
ORDER BY created_at DESC, id DESC
LIMIT 50 OFFSET 100;

\echo
\echo Q2_category_brand_status_price_price_asc_shallow
EXPLAIN (ANALYZE, BUFFERS, VERBOSE)
SELECT
    id,
    seller_id,
    category_id,
    brand_id,
    status,
    price,
    rating,
    review_count,
    created_at,
    updated_at
FROM :target_table
WHERE category_id = 35
  AND brand_id = 543
  AND status = 'ACTIVE'
  AND price BETWEEN 10000 AND 100000
ORDER BY price ASC, id ASC
LIMIT 50 OFFSET 100;

\echo
\echo Q3_category_status_review_count_shallow
EXPLAIN (ANALYZE, BUFFERS, VERBOSE)
SELECT
    id,
    seller_id,
    category_id,
    brand_id,
    status,
    price,
    rating,
    review_count,
    created_at,
    updated_at
FROM :target_table
WHERE category_id = 35
  AND status = 'ACTIVE'
ORDER BY review_count DESC, id DESC
LIMIT 50 OFFSET 100;

\echo
\echo Q4_category_status_price_created_at_deep_offset
EXPLAIN (ANALYZE, BUFFERS, VERBOSE)
SELECT
    id,
    seller_id,
    category_id,
    brand_id,
    status,
    price,
    rating,
    review_count,
    created_at,
    updated_at
FROM :target_table
WHERE category_id = 35
  AND status = 'ACTIVE'
  AND price BETWEEN 10000 AND 100000
ORDER BY created_at DESC, id DESC
LIMIT 50 OFFSET 10000;

\echo
\echo Q5_status_only_created_at_shallow
EXPLAIN (ANALYZE, BUFFERS, VERBOSE)
SELECT
    id,
    seller_id,
    category_id,
    brand_id,
    status,
    price,
    rating,
    review_count,
    created_at,
    updated_at
FROM :target_table
WHERE status = 'ACTIVE'
ORDER BY created_at DESC, id DESC
LIMIT 50 OFFSET 100;

\echo
\echo Q6_price_range_price_asc_shallow
EXPLAIN (ANALYZE, BUFFERS, VERBOSE)
SELECT
    id,
    seller_id,
    category_id,
    brand_id,
    status,
    price,
    rating,
    review_count,
    created_at,
    updated_at
FROM :target_table
WHERE price BETWEEN 10000 AND 100000
ORDER BY price ASC, id ASC
LIMIT 50 OFFSET 100;
