\set ON_ERROR_STOP on
\timing on
\pset pager off

-- A-1a products-only keyset pagination comparison experiment.
--
-- Supported psql variable:
--   -v target_table=products_uniform
--   -v target_table=products_moderate_skew
--   -v target_table=products_high_skew
--
-- If target_table is omitted, products_moderate_skew is used.
-- This script compares Q4 deep OFFSET with a keyset query using the same
-- products-only filter and ordering shape. The cursor derivation query is
-- experiment setup only and is not part of the keyset read path.

\if :{?target_table}
\else
\set target_table 'products_moderate_skew'
\endif

\echo experiment_start

CREATE TEMP TABLE products_keyset_pagination_comparison_config (
    target_table TEXT NOT NULL
);

INSERT INTO products_keyset_pagination_comparison_config (target_table)
VALUES (:'target_table');

DO $$
DECLARE
    selected_target_table TEXT;
BEGIN
    SELECT target_table
    INTO selected_target_table
    FROM products_keyset_pagination_comparison_config;

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
    'A-1a products keyset pagination comparison' AS experiment,
    now() AS executed_at,
    version() AS postgres_version,
    current_database() AS database_name,
    current_user AS database_user,
    :'target_table' AS target_table;

\echo
\echo target_table_info

SELECT :'target_table' AS target_table, COUNT(*) AS product_count
FROM :target_table;

SELECT
    table_name,
    column_name,
    data_type
FROM information_schema.columns
WHERE table_schema = 'public'
  AND table_name = :'target_table'
  AND column_name IN ('id', 'category_id', 'status', 'price', 'created_at')
ORDER BY ordinal_position;

\echo
\echo cleanup_existing_keyset_experiment_index_before_start

DO $$
DECLARE
    selected_target_table TEXT;
BEGIN
    SELECT target_table
    INTO selected_target_table
    FROM products_keyset_pagination_comparison_config;

    EXECUTE format('DROP INDEX IF EXISTS %I', 'idx_exp_' || selected_target_table || '_keyset_active_cat_created_id');
END $$;

\echo
\echo create_supporting_index

DO $$
DECLARE
    selected_target_table TEXT;
BEGIN
    SELECT target_table
    INTO selected_target_table
    FROM products_keyset_pagination_comparison_config;

    EXECUTE format(
        'CREATE INDEX %I ON %I (category_id, created_at DESC, id DESC) WHERE status = ''ACTIVE''',
        'idx_exp_' || selected_target_table || '_keyset_active_cat_created_id',
        selected_target_table
    );
END $$;

ANALYZE :target_table;

\echo
\echo derive_q4_keyset_cursor
\echo cursor_derivation_is_experiment_setup_only_not_keyset_read_path

SELECT
    created_at AS cursor_created_at,
    id AS cursor_id
FROM :target_table
WHERE category_id = 35
  AND status = 'ACTIVE'
  AND price BETWEEN 10000 AND 100000
ORDER BY created_at DESC, id DESC
LIMIT 1 OFFSET 9999
\gset q4_

SELECT
    :'target_table' AS target_table,
    :'q4_cursor_created_at'::timestamp AS cursor_created_at,
    :q4_cursor_id::bigint AS cursor_id,
    'Derived from OFFSET 9999 LIMIT 1 for local reproducibility only' AS cursor_note;

\echo
\echo q4_offset_deep_explain

EXPLAIN (ANALYZE, BUFFERS, VERBOSE)
SELECT id, seller_id, category_id, brand_id, status, price, rating, review_count, created_at, updated_at
FROM :target_table
WHERE category_id = 35
  AND status = 'ACTIVE'
  AND price BETWEEN 10000 AND 100000
ORDER BY created_at DESC, id DESC
LIMIT 50 OFFSET 10000;

\echo
\echo q4_keyset_explain

EXPLAIN (ANALYZE, BUFFERS, VERBOSE)
SELECT id, seller_id, category_id, brand_id, status, price, rating, review_count, created_at, updated_at
FROM :target_table
WHERE category_id = 35
  AND status = 'ACTIVE'
  AND price BETWEEN 10000 AND 100000
  AND (created_at, id) < (:'q4_cursor_created_at'::timestamp, :q4_cursor_id::bigint)
ORDER BY created_at DESC, id DESC
LIMIT 50;

\echo
\echo optional_result_equivalence_check

WITH
offset_page AS (
    SELECT
        row_number() OVER (ORDER BY created_at DESC, id DESC) AS row_number,
        id
    FROM (
        SELECT id, created_at
        FROM :target_table
        WHERE category_id = 35
          AND status = 'ACTIVE'
          AND price BETWEEN 10000 AND 100000
        ORDER BY created_at DESC, id DESC
        LIMIT 50 OFFSET 10000
    ) page
),
keyset_page AS (
    SELECT
        row_number() OVER (ORDER BY created_at DESC, id DESC) AS row_number,
        id
    FROM (
        SELECT id, created_at
        FROM :target_table
        WHERE category_id = 35
          AND status = 'ACTIVE'
          AND price BETWEEN 10000 AND 100000
          AND (created_at, id) < (:'q4_cursor_created_at'::timestamp, :q4_cursor_id::bigint)
        ORDER BY created_at DESC, id DESC
        LIMIT 50
    ) page
),
offset_ids AS (
    SELECT COALESCE(array_agg(id ORDER BY row_number), ARRAY[]::bigint[]) AS ids
    FROM offset_page
),
keyset_ids AS (
    SELECT COALESCE(array_agg(id ORDER BY row_number), ARRAY[]::bigint[]) AS ids
    FROM keyset_page
)
SELECT
    (SELECT COUNT(*) FROM offset_page) AS offset_page_count,
    (SELECT COUNT(*) FROM keyset_page) AS keyset_page_count,
    (SELECT ids FROM offset_ids) = (SELECT ids FROM keyset_ids) AS ids_match,
    'Correctness sanity check only; not a performance benchmark' AS check_note;

\echo
\echo drop_supporting_index

DO $$
DECLARE
    selected_target_table TEXT;
BEGIN
    SELECT target_table
    INTO selected_target_table
    FROM products_keyset_pagination_comparison_config;

    EXECUTE format('DROP INDEX IF EXISTS %I', 'idx_exp_' || selected_target_table || '_keyset_active_cat_created_id');
END $$;

ANALYZE :target_table;

\echo
\echo verify_no_experiment_indexes_remain

SELECT tablename, indexname
FROM pg_indexes
WHERE schemaname = 'public'
  AND indexname LIKE 'idx_exp_%'
ORDER BY tablename, indexname;
