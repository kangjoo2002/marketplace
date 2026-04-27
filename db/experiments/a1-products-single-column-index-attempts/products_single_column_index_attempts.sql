\set ON_ERROR_STOP on
\timing on
\pset pager off

-- A-1a products-only single-column index attempt experiment.
--
-- Supported psql variable:
--   -v target_table=products_uniform
--   -v target_table=products_moderate_skew
--   -v target_table=products_high_skew
--
-- If target_table is omitted, products_moderate_skew is used.
-- This script creates one experiment index at a time, runs Q1-Q6, then drops
-- the index before moving to the next attempt. These are local experiment
-- indexes, not permanent schema changes.

\if :{?target_table}
\else
\set target_table 'products_moderate_skew'
\endif

CREATE TEMP TABLE products_single_column_index_attempt_config (
    target_table TEXT NOT NULL
);

INSERT INTO products_single_column_index_attempt_config (target_table)
VALUES (:'target_table');

DO $$
DECLARE
    selected_target_table TEXT;
BEGIN
    SELECT target_table
    INTO selected_target_table
    FROM products_single_column_index_attempt_config;

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
    now() AS executed_at,
    version() AS postgres_version,
    current_database() AS database_name,
    current_user AS database_user,
    :'target_table' AS target_table;

SELECT :'target_table' AS target_table, COUNT(*) AS product_count
FROM :target_table;

\echo
\echo cleanup_existing_experiment_indexes_before_start
DO $$
DECLARE
    selected_target_table TEXT;
BEGIN
    SELECT target_table
    INTO selected_target_table
    FROM products_single_column_index_attempt_config;

    EXECUTE format('DROP INDEX IF EXISTS %I', 'idx_exp_' || selected_target_table || '_status');
    EXECUTE format('DROP INDEX IF EXISTS %I', 'idx_exp_' || selected_target_table || '_price');
    EXECUTE format('DROP INDEX IF EXISTS %I', 'idx_exp_' || selected_target_table || '_created_at');
    EXECUTE format('DROP INDEX IF EXISTS %I', 'idx_exp_' || selected_target_table || '_review_count');
END $$;

\echo
\echo ATTEMPT_status_single_column_index
DO $$
DECLARE
    selected_target_table TEXT;
BEGIN
    SELECT target_table
    INTO selected_target_table
    FROM products_single_column_index_attempt_config;

    EXECUTE format('DROP INDEX IF EXISTS %I', 'idx_exp_' || selected_target_table || '_status');
    EXECUTE format('CREATE INDEX %I ON %I (status)', 'idx_exp_' || selected_target_table || '_status', selected_target_table);
END $$;

ANALYZE :target_table;

\echo status_index__Q1_category_status_price_created_at_shallow
EXPLAIN (ANALYZE, BUFFERS, VERBOSE)
SELECT id, seller_id, category_id, brand_id, status, price, rating, review_count, created_at, updated_at
FROM :target_table
WHERE category_id = 35
  AND status = 'ACTIVE'
  AND price BETWEEN 10000 AND 100000
ORDER BY created_at DESC, id DESC
LIMIT 50 OFFSET 100;

\echo status_index__Q2_category_brand_status_price_price_asc_shallow
EXPLAIN (ANALYZE, BUFFERS, VERBOSE)
SELECT id, seller_id, category_id, brand_id, status, price, rating, review_count, created_at, updated_at
FROM :target_table
WHERE category_id = 35
  AND brand_id = 543
  AND status = 'ACTIVE'
  AND price BETWEEN 10000 AND 100000
ORDER BY price ASC, id ASC
LIMIT 50 OFFSET 100;

\echo status_index__Q3_category_status_review_count_shallow
EXPLAIN (ANALYZE, BUFFERS, VERBOSE)
SELECT id, seller_id, category_id, brand_id, status, price, rating, review_count, created_at, updated_at
FROM :target_table
WHERE category_id = 35
  AND status = 'ACTIVE'
ORDER BY review_count DESC, id DESC
LIMIT 50 OFFSET 100;

\echo status_index__Q4_category_status_price_created_at_deep_offset
EXPLAIN (ANALYZE, BUFFERS, VERBOSE)
SELECT id, seller_id, category_id, brand_id, status, price, rating, review_count, created_at, updated_at
FROM :target_table
WHERE category_id = 35
  AND status = 'ACTIVE'
  AND price BETWEEN 10000 AND 100000
ORDER BY created_at DESC, id DESC
LIMIT 50 OFFSET 10000;

\echo status_index__Q5_status_only_created_at_shallow
EXPLAIN (ANALYZE, BUFFERS, VERBOSE)
SELECT id, seller_id, category_id, brand_id, status, price, rating, review_count, created_at, updated_at
FROM :target_table
WHERE status = 'ACTIVE'
ORDER BY created_at DESC, id DESC
LIMIT 50 OFFSET 100;

\echo status_index__Q6_price_range_price_asc_shallow
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
    FROM products_single_column_index_attempt_config;

    EXECUTE format('DROP INDEX IF EXISTS %I', 'idx_exp_' || selected_target_table || '_status');
END $$;

ANALYZE :target_table;

\echo
\echo ATTEMPT_price_single_column_index
DO $$
DECLARE
    selected_target_table TEXT;
BEGIN
    SELECT target_table
    INTO selected_target_table
    FROM products_single_column_index_attempt_config;

    EXECUTE format('DROP INDEX IF EXISTS %I', 'idx_exp_' || selected_target_table || '_price');
    EXECUTE format('CREATE INDEX %I ON %I (price)', 'idx_exp_' || selected_target_table || '_price', selected_target_table);
END $$;

ANALYZE :target_table;

\echo price_index__Q1_category_status_price_created_at_shallow
EXPLAIN (ANALYZE, BUFFERS, VERBOSE)
SELECT id, seller_id, category_id, brand_id, status, price, rating, review_count, created_at, updated_at
FROM :target_table
WHERE category_id = 35
  AND status = 'ACTIVE'
  AND price BETWEEN 10000 AND 100000
ORDER BY created_at DESC, id DESC
LIMIT 50 OFFSET 100;

\echo price_index__Q2_category_brand_status_price_price_asc_shallow
EXPLAIN (ANALYZE, BUFFERS, VERBOSE)
SELECT id, seller_id, category_id, brand_id, status, price, rating, review_count, created_at, updated_at
FROM :target_table
WHERE category_id = 35
  AND brand_id = 543
  AND status = 'ACTIVE'
  AND price BETWEEN 10000 AND 100000
ORDER BY price ASC, id ASC
LIMIT 50 OFFSET 100;

\echo price_index__Q3_category_status_review_count_shallow
EXPLAIN (ANALYZE, BUFFERS, VERBOSE)
SELECT id, seller_id, category_id, brand_id, status, price, rating, review_count, created_at, updated_at
FROM :target_table
WHERE category_id = 35
  AND status = 'ACTIVE'
ORDER BY review_count DESC, id DESC
LIMIT 50 OFFSET 100;

\echo price_index__Q4_category_status_price_created_at_deep_offset
EXPLAIN (ANALYZE, BUFFERS, VERBOSE)
SELECT id, seller_id, category_id, brand_id, status, price, rating, review_count, created_at, updated_at
FROM :target_table
WHERE category_id = 35
  AND status = 'ACTIVE'
  AND price BETWEEN 10000 AND 100000
ORDER BY created_at DESC, id DESC
LIMIT 50 OFFSET 10000;

\echo price_index__Q5_status_only_created_at_shallow
EXPLAIN (ANALYZE, BUFFERS, VERBOSE)
SELECT id, seller_id, category_id, brand_id, status, price, rating, review_count, created_at, updated_at
FROM :target_table
WHERE status = 'ACTIVE'
ORDER BY created_at DESC, id DESC
LIMIT 50 OFFSET 100;

\echo price_index__Q6_price_range_price_asc_shallow
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
    FROM products_single_column_index_attempt_config;

    EXECUTE format('DROP INDEX IF EXISTS %I', 'idx_exp_' || selected_target_table || '_price');
END $$;

ANALYZE :target_table;

\echo
\echo ATTEMPT_created_at_single_column_index
DO $$
DECLARE
    selected_target_table TEXT;
BEGIN
    SELECT target_table
    INTO selected_target_table
    FROM products_single_column_index_attempt_config;

    EXECUTE format('DROP INDEX IF EXISTS %I', 'idx_exp_' || selected_target_table || '_created_at');
    EXECUTE format('CREATE INDEX %I ON %I (created_at)', 'idx_exp_' || selected_target_table || '_created_at', selected_target_table);
END $$;

ANALYZE :target_table;

\echo created_at_index__Q1_category_status_price_created_at_shallow
EXPLAIN (ANALYZE, BUFFERS, VERBOSE)
SELECT id, seller_id, category_id, brand_id, status, price, rating, review_count, created_at, updated_at
FROM :target_table
WHERE category_id = 35
  AND status = 'ACTIVE'
  AND price BETWEEN 10000 AND 100000
ORDER BY created_at DESC, id DESC
LIMIT 50 OFFSET 100;

\echo created_at_index__Q2_category_brand_status_price_price_asc_shallow
EXPLAIN (ANALYZE, BUFFERS, VERBOSE)
SELECT id, seller_id, category_id, brand_id, status, price, rating, review_count, created_at, updated_at
FROM :target_table
WHERE category_id = 35
  AND brand_id = 543
  AND status = 'ACTIVE'
  AND price BETWEEN 10000 AND 100000
ORDER BY price ASC, id ASC
LIMIT 50 OFFSET 100;

\echo created_at_index__Q3_category_status_review_count_shallow
EXPLAIN (ANALYZE, BUFFERS, VERBOSE)
SELECT id, seller_id, category_id, brand_id, status, price, rating, review_count, created_at, updated_at
FROM :target_table
WHERE category_id = 35
  AND status = 'ACTIVE'
ORDER BY review_count DESC, id DESC
LIMIT 50 OFFSET 100;

\echo created_at_index__Q4_category_status_price_created_at_deep_offset
EXPLAIN (ANALYZE, BUFFERS, VERBOSE)
SELECT id, seller_id, category_id, brand_id, status, price, rating, review_count, created_at, updated_at
FROM :target_table
WHERE category_id = 35
  AND status = 'ACTIVE'
  AND price BETWEEN 10000 AND 100000
ORDER BY created_at DESC, id DESC
LIMIT 50 OFFSET 10000;

\echo created_at_index__Q5_status_only_created_at_shallow
EXPLAIN (ANALYZE, BUFFERS, VERBOSE)
SELECT id, seller_id, category_id, brand_id, status, price, rating, review_count, created_at, updated_at
FROM :target_table
WHERE status = 'ACTIVE'
ORDER BY created_at DESC, id DESC
LIMIT 50 OFFSET 100;

\echo created_at_index__Q6_price_range_price_asc_shallow
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
    FROM products_single_column_index_attempt_config;

    EXECUTE format('DROP INDEX IF EXISTS %I', 'idx_exp_' || selected_target_table || '_created_at');
END $$;

ANALYZE :target_table;

\echo
\echo ATTEMPT_review_count_single_column_index
DO $$
DECLARE
    selected_target_table TEXT;
BEGIN
    SELECT target_table
    INTO selected_target_table
    FROM products_single_column_index_attempt_config;

    EXECUTE format('DROP INDEX IF EXISTS %I', 'idx_exp_' || selected_target_table || '_review_count');
    EXECUTE format('CREATE INDEX %I ON %I (review_count)', 'idx_exp_' || selected_target_table || '_review_count', selected_target_table);
END $$;

ANALYZE :target_table;

\echo review_count_index__Q1_category_status_price_created_at_shallow
EXPLAIN (ANALYZE, BUFFERS, VERBOSE)
SELECT id, seller_id, category_id, brand_id, status, price, rating, review_count, created_at, updated_at
FROM :target_table
WHERE category_id = 35
  AND status = 'ACTIVE'
  AND price BETWEEN 10000 AND 100000
ORDER BY created_at DESC, id DESC
LIMIT 50 OFFSET 100;

\echo review_count_index__Q2_category_brand_status_price_price_asc_shallow
EXPLAIN (ANALYZE, BUFFERS, VERBOSE)
SELECT id, seller_id, category_id, brand_id, status, price, rating, review_count, created_at, updated_at
FROM :target_table
WHERE category_id = 35
  AND brand_id = 543
  AND status = 'ACTIVE'
  AND price BETWEEN 10000 AND 100000
ORDER BY price ASC, id ASC
LIMIT 50 OFFSET 100;

\echo review_count_index__Q3_category_status_review_count_shallow
EXPLAIN (ANALYZE, BUFFERS, VERBOSE)
SELECT id, seller_id, category_id, brand_id, status, price, rating, review_count, created_at, updated_at
FROM :target_table
WHERE category_id = 35
  AND status = 'ACTIVE'
ORDER BY review_count DESC, id DESC
LIMIT 50 OFFSET 100;

\echo review_count_index__Q4_category_status_price_created_at_deep_offset
EXPLAIN (ANALYZE, BUFFERS, VERBOSE)
SELECT id, seller_id, category_id, brand_id, status, price, rating, review_count, created_at, updated_at
FROM :target_table
WHERE category_id = 35
  AND status = 'ACTIVE'
  AND price BETWEEN 10000 AND 100000
ORDER BY created_at DESC, id DESC
LIMIT 50 OFFSET 10000;

\echo review_count_index__Q5_status_only_created_at_shallow
EXPLAIN (ANALYZE, BUFFERS, VERBOSE)
SELECT id, seller_id, category_id, brand_id, status, price, rating, review_count, created_at, updated_at
FROM :target_table
WHERE status = 'ACTIVE'
ORDER BY created_at DESC, id DESC
LIMIT 50 OFFSET 100;

\echo review_count_index__Q6_price_range_price_asc_shallow
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
    FROM products_single_column_index_attempt_config;

    EXECUTE format('DROP INDEX IF EXISTS %I', 'idx_exp_' || selected_target_table || '_review_count');
END $$;

ANALYZE :target_table;

\echo
\echo verify_no_experiment_indexes_remain
SELECT
    indexname
FROM pg_indexes
WHERE schemaname = 'public'
  AND tablename = :'target_table'
  AND indexname LIKE 'idx_exp_%'
ORDER BY indexname;
