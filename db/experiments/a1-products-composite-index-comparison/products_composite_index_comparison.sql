\set ON_ERROR_STOP on
\timing on
\pset pager off

-- A-1a products-only composite index comparison experiment.
--
-- Supported psql variable:
--   -v target_table=products_uniform
--   -v target_table=products_moderate_skew
--   -v target_table=products_high_skew
--
-- If target_table is omitted, products_moderate_skew is used.
-- This script creates one experiment index candidate at a time, runs Q1-Q6,
-- drops the candidate, and then moves to the next candidate.

\if :{?target_table}
\else
\set target_table 'products_moderate_skew'
\endif

CREATE TEMP TABLE products_composite_index_comparison_config (
    target_table TEXT NOT NULL
);

INSERT INTO products_composite_index_comparison_config (target_table)
VALUES (:'target_table');

DO $$
DECLARE
    selected_target_table TEXT;
BEGIN
    SELECT target_table
    INTO selected_target_table
    FROM products_composite_index_comparison_config;

    IF selected_target_table NOT IN (
        'products_uniform',
        'products_moderate_skew',
        'products_high_skew'
    ) THEN
        RAISE EXCEPTION
            'Unsupported target_table: %. Supported values: products_uniform, products_moderate_skew, products_high_skew',
            selected_target_table;
    END IF;

    IF to_regclass(selected_target_table) IS NULL THEN
        RAISE EXCEPTION 'target_table does not exist: %', selected_target_table;
    END IF;
END $$;

SELECT
    'A-1a products composite index comparison' AS experiment,
    now() AS executed_at,
    version() AS postgres_version,
    current_database() AS database_name,
    current_user AS database_user,
    :'target_table' AS target_table;

SELECT :'target_table' AS target_table, COUNT(*) AS product_count
FROM :target_table;

\echo
\echo cleanup_existing_composite_experiment_indexes_before_start
DO $$
DECLARE
    selected_target_table TEXT;
BEGIN
    SELECT target_table
    INTO selected_target_table
    FROM products_composite_index_comparison_config;

    EXECUTE format('DROP INDEX IF EXISTS %I', 'idx_exp_' || selected_target_table || '_cat_status_created_id');
    EXECUTE format('DROP INDEX IF EXISTS %I', 'idx_exp_' || selected_target_table || '_cat_status_price_created_id');
    EXECUTE format('DROP INDEX IF EXISTS %I', 'idx_exp_' || selected_target_table || '_cat_brand_status_price_id');
    EXECUTE format('DROP INDEX IF EXISTS %I', 'idx_exp_' || selected_target_table || '_cat_status_review_id');
END $$;

\echo
\echo CANDIDATE_1_category_status_latest
DO $$
DECLARE
    selected_target_table TEXT;
BEGIN
    SELECT target_table
    INTO selected_target_table
    FROM products_composite_index_comparison_config;

    EXECUTE format('DROP INDEX IF EXISTS %I', 'idx_exp_' || selected_target_table || '_cat_status_created_id');
    EXECUTE format(
        'CREATE INDEX %I ON %I (category_id, status, created_at DESC, id DESC)',
        'idx_exp_' || selected_target_table || '_cat_status_created_id',
        selected_target_table
    );
END $$;

ANALYZE :target_table;

\echo candidate_1_cat_status_latest__Q1_category_status_price_created_at_shallow
EXPLAIN (ANALYZE, BUFFERS, VERBOSE)
SELECT id, seller_id, category_id, brand_id, status, price, rating, review_count, created_at, updated_at
FROM :target_table
WHERE category_id = 35
  AND status = 'ACTIVE'
  AND price BETWEEN 10000 AND 100000
ORDER BY created_at DESC, id DESC
LIMIT 50 OFFSET 100;

\echo candidate_1_cat_status_latest__Q2_category_brand_status_price_price_asc_shallow
EXPLAIN (ANALYZE, BUFFERS, VERBOSE)
SELECT id, seller_id, category_id, brand_id, status, price, rating, review_count, created_at, updated_at
FROM :target_table
WHERE category_id = 35
  AND brand_id = 543
  AND status = 'ACTIVE'
  AND price BETWEEN 10000 AND 100000
ORDER BY price ASC, id ASC
LIMIT 50 OFFSET 100;

\echo candidate_1_cat_status_latest__Q3_category_status_review_count_shallow
EXPLAIN (ANALYZE, BUFFERS, VERBOSE)
SELECT id, seller_id, category_id, brand_id, status, price, rating, review_count, created_at, updated_at
FROM :target_table
WHERE category_id = 35
  AND status = 'ACTIVE'
ORDER BY review_count DESC, id DESC
LIMIT 50 OFFSET 100;

\echo candidate_1_cat_status_latest__Q4_category_status_price_created_at_deep_offset
EXPLAIN (ANALYZE, BUFFERS, VERBOSE)
SELECT id, seller_id, category_id, brand_id, status, price, rating, review_count, created_at, updated_at
FROM :target_table
WHERE category_id = 35
  AND status = 'ACTIVE'
  AND price BETWEEN 10000 AND 100000
ORDER BY created_at DESC, id DESC
LIMIT 50 OFFSET 10000;

\echo candidate_1_cat_status_latest__Q5_status_only_created_at_shallow
EXPLAIN (ANALYZE, BUFFERS, VERBOSE)
SELECT id, seller_id, category_id, brand_id, status, price, rating, review_count, created_at, updated_at
FROM :target_table
WHERE status = 'ACTIVE'
ORDER BY created_at DESC, id DESC
LIMIT 50 OFFSET 100;

\echo candidate_1_cat_status_latest__Q6_price_range_price_asc_shallow
EXPLAIN (ANALYZE, BUFFERS, VERBOSE)
SELECT id, seller_id, category_id, brand_id, status, price, rating, review_count, created_at, updated_at
FROM :target_table
WHERE price BETWEEN 10000 AND 100000
ORDER BY price ASC, id ASC
LIMIT 50 OFFSET 100;

DO $$
DECLARE
    selected_target_table TEXT;
BEGIN
    SELECT target_table
    INTO selected_target_table
    FROM products_composite_index_comparison_config;

    EXECUTE format('DROP INDEX IF EXISTS %I', 'idx_exp_' || selected_target_table || '_cat_status_created_id');
END $$;

ANALYZE :target_table;

\echo
\echo CANDIDATE_2_category_status_price_latest
DO $$
DECLARE
    selected_target_table TEXT;
BEGIN
    SELECT target_table
    INTO selected_target_table
    FROM products_composite_index_comparison_config;

    EXECUTE format('DROP INDEX IF EXISTS %I', 'idx_exp_' || selected_target_table || '_cat_status_price_created_id');
    EXECUTE format(
        'CREATE INDEX %I ON %I (category_id, status, price, created_at DESC, id DESC)',
        'idx_exp_' || selected_target_table || '_cat_status_price_created_id',
        selected_target_table
    );
END $$;

ANALYZE :target_table;

\echo candidate_2_cat_status_price_latest__Q1_category_status_price_created_at_shallow
EXPLAIN (ANALYZE, BUFFERS, VERBOSE)
SELECT id, seller_id, category_id, brand_id, status, price, rating, review_count, created_at, updated_at
FROM :target_table
WHERE category_id = 35
  AND status = 'ACTIVE'
  AND price BETWEEN 10000 AND 100000
ORDER BY created_at DESC, id DESC
LIMIT 50 OFFSET 100;

\echo candidate_2_cat_status_price_latest__Q2_category_brand_status_price_price_asc_shallow
EXPLAIN (ANALYZE, BUFFERS, VERBOSE)
SELECT id, seller_id, category_id, brand_id, status, price, rating, review_count, created_at, updated_at
FROM :target_table
WHERE category_id = 35
  AND brand_id = 543
  AND status = 'ACTIVE'
  AND price BETWEEN 10000 AND 100000
ORDER BY price ASC, id ASC
LIMIT 50 OFFSET 100;

\echo candidate_2_cat_status_price_latest__Q3_category_status_review_count_shallow
EXPLAIN (ANALYZE, BUFFERS, VERBOSE)
SELECT id, seller_id, category_id, brand_id, status, price, rating, review_count, created_at, updated_at
FROM :target_table
WHERE category_id = 35
  AND status = 'ACTIVE'
ORDER BY review_count DESC, id DESC
LIMIT 50 OFFSET 100;

\echo candidate_2_cat_status_price_latest__Q4_category_status_price_created_at_deep_offset
EXPLAIN (ANALYZE, BUFFERS, VERBOSE)
SELECT id, seller_id, category_id, brand_id, status, price, rating, review_count, created_at, updated_at
FROM :target_table
WHERE category_id = 35
  AND status = 'ACTIVE'
  AND price BETWEEN 10000 AND 100000
ORDER BY created_at DESC, id DESC
LIMIT 50 OFFSET 10000;

\echo candidate_2_cat_status_price_latest__Q5_status_only_created_at_shallow
EXPLAIN (ANALYZE, BUFFERS, VERBOSE)
SELECT id, seller_id, category_id, brand_id, status, price, rating, review_count, created_at, updated_at
FROM :target_table
WHERE status = 'ACTIVE'
ORDER BY created_at DESC, id DESC
LIMIT 50 OFFSET 100;

\echo candidate_2_cat_status_price_latest__Q6_price_range_price_asc_shallow
EXPLAIN (ANALYZE, BUFFERS, VERBOSE)
SELECT id, seller_id, category_id, brand_id, status, price, rating, review_count, created_at, updated_at
FROM :target_table
WHERE price BETWEEN 10000 AND 100000
ORDER BY price ASC, id ASC
LIMIT 50 OFFSET 100;

DO $$
DECLARE
    selected_target_table TEXT;
BEGIN
    SELECT target_table
    INTO selected_target_table
    FROM products_composite_index_comparison_config;

    EXECUTE format('DROP INDEX IF EXISTS %I', 'idx_exp_' || selected_target_table || '_cat_status_price_created_id');
END $$;

ANALYZE :target_table;

\echo
\echo CANDIDATE_3_category_brand_status_price
DO $$
DECLARE
    selected_target_table TEXT;
BEGIN
    SELECT target_table
    INTO selected_target_table
    FROM products_composite_index_comparison_config;

    EXECUTE format('DROP INDEX IF EXISTS %I', 'idx_exp_' || selected_target_table || '_cat_brand_status_price_id');
    EXECUTE format(
        'CREATE INDEX %I ON %I (category_id, brand_id, status, price ASC, id ASC)',
        'idx_exp_' || selected_target_table || '_cat_brand_status_price_id',
        selected_target_table
    );
END $$;

ANALYZE :target_table;

\echo candidate_3_cat_brand_status_price__Q1_category_status_price_created_at_shallow
EXPLAIN (ANALYZE, BUFFERS, VERBOSE)
SELECT id, seller_id, category_id, brand_id, status, price, rating, review_count, created_at, updated_at
FROM :target_table
WHERE category_id = 35
  AND status = 'ACTIVE'
  AND price BETWEEN 10000 AND 100000
ORDER BY created_at DESC, id DESC
LIMIT 50 OFFSET 100;

\echo candidate_3_cat_brand_status_price__Q2_category_brand_status_price_price_asc_shallow
EXPLAIN (ANALYZE, BUFFERS, VERBOSE)
SELECT id, seller_id, category_id, brand_id, status, price, rating, review_count, created_at, updated_at
FROM :target_table
WHERE category_id = 35
  AND brand_id = 543
  AND status = 'ACTIVE'
  AND price BETWEEN 10000 AND 100000
ORDER BY price ASC, id ASC
LIMIT 50 OFFSET 100;

\echo candidate_3_cat_brand_status_price__Q3_category_status_review_count_shallow
EXPLAIN (ANALYZE, BUFFERS, VERBOSE)
SELECT id, seller_id, category_id, brand_id, status, price, rating, review_count, created_at, updated_at
FROM :target_table
WHERE category_id = 35
  AND status = 'ACTIVE'
ORDER BY review_count DESC, id DESC
LIMIT 50 OFFSET 100;

\echo candidate_3_cat_brand_status_price__Q4_category_status_price_created_at_deep_offset
EXPLAIN (ANALYZE, BUFFERS, VERBOSE)
SELECT id, seller_id, category_id, brand_id, status, price, rating, review_count, created_at, updated_at
FROM :target_table
WHERE category_id = 35
  AND status = 'ACTIVE'
  AND price BETWEEN 10000 AND 100000
ORDER BY created_at DESC, id DESC
LIMIT 50 OFFSET 10000;

\echo candidate_3_cat_brand_status_price__Q5_status_only_created_at_shallow
EXPLAIN (ANALYZE, BUFFERS, VERBOSE)
SELECT id, seller_id, category_id, brand_id, status, price, rating, review_count, created_at, updated_at
FROM :target_table
WHERE status = 'ACTIVE'
ORDER BY created_at DESC, id DESC
LIMIT 50 OFFSET 100;

\echo candidate_3_cat_brand_status_price__Q6_price_range_price_asc_shallow
EXPLAIN (ANALYZE, BUFFERS, VERBOSE)
SELECT id, seller_id, category_id, brand_id, status, price, rating, review_count, created_at, updated_at
FROM :target_table
WHERE price BETWEEN 10000 AND 100000
ORDER BY price ASC, id ASC
LIMIT 50 OFFSET 100;

DO $$
DECLARE
    selected_target_table TEXT;
BEGIN
    SELECT target_table
    INTO selected_target_table
    FROM products_composite_index_comparison_config;

    EXECUTE format('DROP INDEX IF EXISTS %I', 'idx_exp_' || selected_target_table || '_cat_brand_status_price_id');
END $$;

ANALYZE :target_table;

\echo
\echo CANDIDATE_4_category_status_review_count
DO $$
DECLARE
    selected_target_table TEXT;
BEGIN
    SELECT target_table
    INTO selected_target_table
    FROM products_composite_index_comparison_config;

    EXECUTE format('DROP INDEX IF EXISTS %I', 'idx_exp_' || selected_target_table || '_cat_status_review_id');
    EXECUTE format(
        'CREATE INDEX %I ON %I (category_id, status, review_count DESC, id DESC)',
        'idx_exp_' || selected_target_table || '_cat_status_review_id',
        selected_target_table
    );
END $$;

ANALYZE :target_table;

\echo candidate_4_cat_status_review__Q1_category_status_price_created_at_shallow
EXPLAIN (ANALYZE, BUFFERS, VERBOSE)
SELECT id, seller_id, category_id, brand_id, status, price, rating, review_count, created_at, updated_at
FROM :target_table
WHERE category_id = 35
  AND status = 'ACTIVE'
  AND price BETWEEN 10000 AND 100000
ORDER BY created_at DESC, id DESC
LIMIT 50 OFFSET 100;

\echo candidate_4_cat_status_review__Q2_category_brand_status_price_price_asc_shallow
EXPLAIN (ANALYZE, BUFFERS, VERBOSE)
SELECT id, seller_id, category_id, brand_id, status, price, rating, review_count, created_at, updated_at
FROM :target_table
WHERE category_id = 35
  AND brand_id = 543
  AND status = 'ACTIVE'
  AND price BETWEEN 10000 AND 100000
ORDER BY price ASC, id ASC
LIMIT 50 OFFSET 100;

\echo candidate_4_cat_status_review__Q3_category_status_review_count_shallow
EXPLAIN (ANALYZE, BUFFERS, VERBOSE)
SELECT id, seller_id, category_id, brand_id, status, price, rating, review_count, created_at, updated_at
FROM :target_table
WHERE category_id = 35
  AND status = 'ACTIVE'
ORDER BY review_count DESC, id DESC
LIMIT 50 OFFSET 100;

\echo candidate_4_cat_status_review__Q4_category_status_price_created_at_deep_offset
EXPLAIN (ANALYZE, BUFFERS, VERBOSE)
SELECT id, seller_id, category_id, brand_id, status, price, rating, review_count, created_at, updated_at
FROM :target_table
WHERE category_id = 35
  AND status = 'ACTIVE'
  AND price BETWEEN 10000 AND 100000
ORDER BY created_at DESC, id DESC
LIMIT 50 OFFSET 10000;

\echo candidate_4_cat_status_review__Q5_status_only_created_at_shallow
EXPLAIN (ANALYZE, BUFFERS, VERBOSE)
SELECT id, seller_id, category_id, brand_id, status, price, rating, review_count, created_at, updated_at
FROM :target_table
WHERE status = 'ACTIVE'
ORDER BY created_at DESC, id DESC
LIMIT 50 OFFSET 100;

\echo candidate_4_cat_status_review__Q6_price_range_price_asc_shallow
EXPLAIN (ANALYZE, BUFFERS, VERBOSE)
SELECT id, seller_id, category_id, brand_id, status, price, rating, review_count, created_at, updated_at
FROM :target_table
WHERE price BETWEEN 10000 AND 100000
ORDER BY price ASC, id ASC
LIMIT 50 OFFSET 100;

DO $$
DECLARE
    selected_target_table TEXT;
BEGIN
    SELECT target_table
    INTO selected_target_table
    FROM products_composite_index_comparison_config;

    EXECUTE format('DROP INDEX IF EXISTS %I', 'idx_exp_' || selected_target_table || '_cat_status_review_id');
END $$;

ANALYZE :target_table;

\echo
\echo verify_no_experiment_indexes_remain
SELECT
    tablename,
    indexname
FROM pg_indexes
WHERE schemaname = 'public'
  AND indexname LIKE 'idx_exp_%'
ORDER BY tablename, indexname;
