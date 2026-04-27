\set ON_ERROR_STOP on
\timing on
\pset pager off

-- A-1b/A-1c products + product_options JOIN + DISTINCT vs EXISTS comparison.
--
-- Supported psql variables:
--   -v products_table=products_uniform
--   -v product_options_table=product_options_uniform
--   -v products_table=products_moderate_skew
--   -v product_options_table=product_options_moderate_skew
--   -v products_table=products_high_skew
--   -v product_options_table=product_options_high_skew
--
-- If omitted, products_moderate_skew + product_options_moderate_skew is used.
-- This script intentionally does not add permanent indexes, rewrite to keyset
-- pagination, modify data, or make API/OpenSearch assumptions.

\if :{?products_table}
\else
\set products_table 'products_moderate_skew'
\endif

\if :{?product_options_table}
\else
\set product_options_table 'product_options_moderate_skew'
\endif

\echo experiment_start

CREATE TEMP TABLE product_options_exists_rewrite_config (
    products_table TEXT NOT NULL,
    product_options_table TEXT NOT NULL,
    common_color TEXT NOT NULL,
    common_size TEXT NOT NULL,
    common_stock_status TEXT NOT NULL,
    less_common_color TEXT NOT NULL,
    less_common_size TEXT NOT NULL,
    less_common_stock_status TEXT NOT NULL
);

INSERT INTO product_options_exists_rewrite_config (
    products_table,
    product_options_table,
    common_color,
    common_size,
    common_stock_status,
    less_common_color,
    less_common_size,
    less_common_stock_status
)
SELECT
    :'products_table',
    :'product_options_table',
    CASE :'products_table'
        WHEN 'products_uniform' THEN 'BEIGE'
        WHEN 'products_moderate_skew' THEN 'WHITE'
        WHEN 'products_high_skew' THEN 'RED'
    END,
    CASE :'products_table'
        WHEN 'products_uniform' THEN 'L'
        WHEN 'products_moderate_skew' THEN 'L'
        WHEN 'products_high_skew' THEN 'M'
    END,
    CASE :'products_table'
        WHEN 'products_uniform' THEN 'IN_STOCK'
        WHEN 'products_moderate_skew' THEN 'OUT_OF_STOCK'
        WHEN 'products_high_skew' THEN 'IN_STOCK'
    END,
    CASE :'products_table'
        WHEN 'products_uniform' THEN 'WHITE'
        WHEN 'products_moderate_skew' THEN 'GRAY'
        WHEN 'products_high_skew' THEN 'BLACK'
    END,
    CASE :'products_table'
        WHEN 'products_uniform' THEN 'S'
        WHEN 'products_moderate_skew' THEN 'L'
        WHEN 'products_high_skew' THEN 'M'
    END,
    CASE :'products_table'
        WHEN 'products_uniform' THEN 'LOW_STOCK'
        WHEN 'products_moderate_skew' THEN 'LOW_STOCK'
        WHEN 'products_high_skew' THEN 'IN_STOCK'
    END;

DO $$
DECLARE
    selected_products_table TEXT;
    selected_product_options_table TEXT;
BEGIN
    SELECT products_table, product_options_table
    INTO selected_products_table, selected_product_options_table
    FROM product_options_exists_rewrite_config;

    IF (selected_products_table, selected_product_options_table) NOT IN (
        ('products_uniform', 'product_options_uniform'),
        ('products_moderate_skew', 'product_options_moderate_skew'),
        ('products_high_skew', 'product_options_high_skew')
    ) THEN
        RAISE EXCEPTION
            'Unsupported or cross-profile table pair: products_table=%, product_options_table=%. Use matched profile pairs only.',
            selected_products_table,
            selected_product_options_table;
    END IF;

    IF to_regclass(selected_products_table) IS NULL THEN
        RAISE EXCEPTION 'products table does not exist: %', selected_products_table;
    END IF;

    IF to_regclass(selected_product_options_table) IS NULL THEN
        RAISE EXCEPTION 'product_options table does not exist: %', selected_product_options_table;
    END IF;
END $$;

\echo
\echo target_table_info

SELECT
    'A-1b/A-1c product_options EXISTS rewrite comparison' AS experiment,
    now() AS executed_at,
    version() AS postgres_version,
    current_database() AS database_name,
    current_user AS database_user,
    products_table,
    product_options_table,
    common_color,
    common_size,
    common_stock_status,
    less_common_color,
    less_common_size,
    less_common_stock_status
FROM product_options_exists_rewrite_config;

SELECT :'products_table' AS products_table, COUNT(*) AS product_count
FROM :products_table;

SELECT :'product_options_table' AS product_options_table, COUNT(*) AS product_options_count
FROM :product_options_table;

\echo
\echo cleanup_existing_product_options_experiment_indexes_before_start

DO $$
DECLARE
    selected_product_options_table TEXT;
BEGIN
    SELECT product_options_table
    INTO selected_product_options_table
    FROM product_options_exists_rewrite_config;

    EXECUTE format('DROP INDEX IF EXISTS %I', 'idx_exp_' || selected_product_options_table || '_exists_color_size_stock_product');
    EXECUTE format('DROP INDEX IF EXISTS %I', 'idx_exp_' || selected_product_options_table || '_exists_product_color_size_stock');
END $$;

\echo
\echo index_family_1_option_filter_first

DO $$
DECLARE
    selected_product_options_table TEXT;
BEGIN
    SELECT product_options_table
    INTO selected_product_options_table
    FROM product_options_exists_rewrite_config;

    EXECUTE format(
        'CREATE INDEX %I ON %I (color, size, stock_status, product_id)',
        'idx_exp_' || selected_product_options_table || '_exists_color_size_stock_product',
        selected_product_options_table
    );
END $$;

ANALYZE :product_options_table;

\echo index_family_1__j1_join_distinct_explain
EXPLAIN (ANALYZE, BUFFERS, VERBOSE)
SELECT DISTINCT p.*
FROM :products_table p
JOIN :product_options_table po
  ON po.product_id = p.id
WHERE p.category_id = 35
  AND p.status = 'ACTIVE'
  AND p.price BETWEEN 10000 AND 100000
  AND po.color = (SELECT common_color FROM product_options_exists_rewrite_config)
  AND po.size = (SELECT common_size FROM product_options_exists_rewrite_config)
  AND po.stock_status = (SELECT common_stock_status FROM product_options_exists_rewrite_config)
ORDER BY p.created_at DESC, p.id DESC
LIMIT 50 OFFSET 100;

\echo index_family_1__j1_exists_explain
EXPLAIN (ANALYZE, BUFFERS, VERBOSE)
SELECT p.*
FROM :products_table p
WHERE p.category_id = 35
  AND p.status = 'ACTIVE'
  AND p.price BETWEEN 10000 AND 100000
  AND EXISTS (
      SELECT 1
      FROM :product_options_table po
      WHERE po.product_id = p.id
        AND po.color = (SELECT common_color FROM product_options_exists_rewrite_config)
        AND po.size = (SELECT common_size FROM product_options_exists_rewrite_config)
        AND po.stock_status = (SELECT common_stock_status FROM product_options_exists_rewrite_config)
  )
ORDER BY p.created_at DESC, p.id DESC
LIMIT 50 OFFSET 100;

\echo index_family_1__j2_join_distinct_explain
EXPLAIN (ANALYZE, BUFFERS, VERBOSE)
SELECT DISTINCT p.*
FROM :products_table p
JOIN :product_options_table po
  ON po.product_id = p.id
WHERE p.category_id = 35
  AND p.brand_id = 543
  AND p.status = 'ACTIVE'
  AND p.price BETWEEN 10000 AND 100000
  AND po.color = (SELECT common_color FROM product_options_exists_rewrite_config)
  AND po.size = (SELECT common_size FROM product_options_exists_rewrite_config)
  AND po.stock_status = (SELECT common_stock_status FROM product_options_exists_rewrite_config)
ORDER BY p.price ASC, p.id ASC
LIMIT 50 OFFSET 100;

\echo index_family_1__j2_exists_explain
EXPLAIN (ANALYZE, BUFFERS, VERBOSE)
SELECT p.*
FROM :products_table p
WHERE p.category_id = 35
  AND p.brand_id = 543
  AND p.status = 'ACTIVE'
  AND p.price BETWEEN 10000 AND 100000
  AND EXISTS (
      SELECT 1
      FROM :product_options_table po
      WHERE po.product_id = p.id
        AND po.color = (SELECT common_color FROM product_options_exists_rewrite_config)
        AND po.size = (SELECT common_size FROM product_options_exists_rewrite_config)
        AND po.stock_status = (SELECT common_stock_status FROM product_options_exists_rewrite_config)
  )
ORDER BY p.price ASC, p.id ASC
LIMIT 50 OFFSET 100;

\echo index_family_1__j3_join_distinct_explain
EXPLAIN (ANALYZE, BUFFERS, VERBOSE)
SELECT DISTINCT p.*
FROM :products_table p
JOIN :product_options_table po
  ON po.product_id = p.id
WHERE p.category_id = 35
  AND p.status = 'ACTIVE'
  AND po.color = (SELECT common_color FROM product_options_exists_rewrite_config)
  AND po.size = (SELECT common_size FROM product_options_exists_rewrite_config)
  AND po.stock_status = (SELECT common_stock_status FROM product_options_exists_rewrite_config)
ORDER BY p.review_count DESC, p.id DESC
LIMIT 50 OFFSET 100;

\echo index_family_1__j3_exists_explain
EXPLAIN (ANALYZE, BUFFERS, VERBOSE)
SELECT p.*
FROM :products_table p
WHERE p.category_id = 35
  AND p.status = 'ACTIVE'
  AND EXISTS (
      SELECT 1
      FROM :product_options_table po
      WHERE po.product_id = p.id
        AND po.color = (SELECT common_color FROM product_options_exists_rewrite_config)
        AND po.size = (SELECT common_size FROM product_options_exists_rewrite_config)
        AND po.stock_status = (SELECT common_stock_status FROM product_options_exists_rewrite_config)
  )
ORDER BY p.review_count DESC, p.id DESC
LIMIT 50 OFFSET 100;

\echo index_family_1__j4_join_distinct_explain
EXPLAIN (ANALYZE, BUFFERS, VERBOSE)
SELECT DISTINCT p.*
FROM :products_table p
JOIN :product_options_table po
  ON po.product_id = p.id
WHERE p.category_id = 35
  AND p.status = 'ACTIVE'
  AND p.price BETWEEN 10000 AND 100000
  AND po.color = (SELECT common_color FROM product_options_exists_rewrite_config)
  AND po.size = (SELECT common_size FROM product_options_exists_rewrite_config)
  AND po.stock_status = (SELECT common_stock_status FROM product_options_exists_rewrite_config)
ORDER BY p.created_at DESC, p.id DESC
LIMIT 50 OFFSET 10000;

\echo index_family_1__j4_exists_explain
EXPLAIN (ANALYZE, BUFFERS, VERBOSE)
SELECT p.*
FROM :products_table p
WHERE p.category_id = 35
  AND p.status = 'ACTIVE'
  AND p.price BETWEEN 10000 AND 100000
  AND EXISTS (
      SELECT 1
      FROM :product_options_table po
      WHERE po.product_id = p.id
        AND po.color = (SELECT common_color FROM product_options_exists_rewrite_config)
        AND po.size = (SELECT common_size FROM product_options_exists_rewrite_config)
        AND po.stock_status = (SELECT common_stock_status FROM product_options_exists_rewrite_config)
  )
ORDER BY p.created_at DESC, p.id DESC
LIMIT 50 OFFSET 10000;

\echo index_family_1__j5_join_distinct_explain
EXPLAIN (ANALYZE, BUFFERS, VERBOSE)
SELECT DISTINCT p.*
FROM :products_table p
JOIN :product_options_table po
  ON po.product_id = p.id
WHERE p.status = 'ACTIVE'
  AND po.color = (SELECT common_color FROM product_options_exists_rewrite_config)
  AND po.size = (SELECT common_size FROM product_options_exists_rewrite_config)
  AND po.stock_status = (SELECT common_stock_status FROM product_options_exists_rewrite_config)
ORDER BY p.created_at DESC, p.id DESC
LIMIT 50 OFFSET 100;

\echo index_family_1__j5_exists_explain
EXPLAIN (ANALYZE, BUFFERS, VERBOSE)
SELECT p.*
FROM :products_table p
WHERE p.status = 'ACTIVE'
  AND EXISTS (
      SELECT 1
      FROM :product_options_table po
      WHERE po.product_id = p.id
        AND po.color = (SELECT common_color FROM product_options_exists_rewrite_config)
        AND po.size = (SELECT common_size FROM product_options_exists_rewrite_config)
        AND po.stock_status = (SELECT common_stock_status FROM product_options_exists_rewrite_config)
  )
ORDER BY p.created_at DESC, p.id DESC
LIMIT 50 OFFSET 100;

\echo index_family_1__j6_option_selectivity_control
SELECT
    control_case,
    color,
    size,
    stock_status,
    joined_option_rows,
    distinct_product_count,
    ROUND(joined_option_rows::NUMERIC / NULLIF(distinct_product_count, 0), 4) AS option_rows_per_distinct_product
FROM (
    SELECT 'common_global' AS control_case, cfg.common_color AS color, cfg.common_size AS size, cfg.common_stock_status AS stock_status, COUNT(*) AS joined_option_rows, COUNT(DISTINCT p.id) AS distinct_product_count
    FROM :products_table p JOIN :product_options_table po ON po.product_id = p.id CROSS JOIN product_options_exists_rewrite_config cfg
    WHERE po.color = cfg.common_color AND po.size = cfg.common_size AND po.stock_status = cfg.common_stock_status
    GROUP BY cfg.common_color, cfg.common_size, cfg.common_stock_status
    UNION ALL
    SELECT 'less_common_global', cfg.less_common_color, cfg.less_common_size, cfg.less_common_stock_status, COUNT(*), COUNT(DISTINCT p.id)
    FROM :products_table p JOIN :product_options_table po ON po.product_id = p.id CROSS JOIN product_options_exists_rewrite_config cfg
    WHERE po.color = cfg.less_common_color AND po.size = cfg.less_common_size AND po.stock_status = cfg.less_common_stock_status
    GROUP BY cfg.less_common_color, cfg.less_common_size, cfg.less_common_stock_status
    UNION ALL
    SELECT 'common_q1_shape', cfg.common_color, cfg.common_size, cfg.common_stock_status, COUNT(*), COUNT(DISTINCT p.id)
    FROM :products_table p JOIN :product_options_table po ON po.product_id = p.id CROSS JOIN product_options_exists_rewrite_config cfg
    WHERE p.category_id = 35 AND p.status = 'ACTIVE' AND p.price BETWEEN 10000 AND 100000
      AND po.color = cfg.common_color AND po.size = cfg.common_size AND po.stock_status = cfg.common_stock_status
    GROUP BY cfg.common_color, cfg.common_size, cfg.common_stock_status
    UNION ALL
    SELECT 'common_q2_shape', cfg.common_color, cfg.common_size, cfg.common_stock_status, COUNT(*), COUNT(DISTINCT p.id)
    FROM :products_table p JOIN :product_options_table po ON po.product_id = p.id CROSS JOIN product_options_exists_rewrite_config cfg
    WHERE p.category_id = 35 AND p.brand_id = 543 AND p.status = 'ACTIVE' AND p.price BETWEEN 10000 AND 100000
      AND po.color = cfg.common_color AND po.size = cfg.common_size AND po.stock_status = cfg.common_stock_status
    GROUP BY cfg.common_color, cfg.common_size, cfg.common_stock_status
    UNION ALL
    SELECT 'less_common_q1_shape', cfg.less_common_color, cfg.less_common_size, cfg.less_common_stock_status, COUNT(*), COUNT(DISTINCT p.id)
    FROM :products_table p JOIN :product_options_table po ON po.product_id = p.id CROSS JOIN product_options_exists_rewrite_config cfg
    WHERE p.category_id = 35 AND p.status = 'ACTIVE' AND p.price BETWEEN 10000 AND 100000
      AND po.color = cfg.less_common_color AND po.size = cfg.less_common_size AND po.stock_status = cfg.less_common_stock_status
    GROUP BY cfg.less_common_color, cfg.less_common_size, cfg.less_common_stock_status
    UNION ALL
    SELECT 'less_common_q2_shape', cfg.less_common_color, cfg.less_common_size, cfg.less_common_stock_status, COUNT(*), COUNT(DISTINCT p.id)
    FROM :products_table p JOIN :product_options_table po ON po.product_id = p.id CROSS JOIN product_options_exists_rewrite_config cfg
    WHERE p.category_id = 35 AND p.brand_id = 543 AND p.status = 'ACTIVE' AND p.price BETWEEN 10000 AND 100000
      AND po.color = cfg.less_common_color AND po.size = cfg.less_common_size AND po.stock_status = cfg.less_common_stock_status
    GROUP BY cfg.less_common_color, cfg.less_common_size, cfg.less_common_stock_status
) controls
ORDER BY control_case;

DO $$
DECLARE
    selected_product_options_table TEXT;
BEGIN
    SELECT product_options_table INTO selected_product_options_table FROM product_options_exists_rewrite_config;
    EXECUTE format('DROP INDEX IF EXISTS %I', 'idx_exp_' || selected_product_options_table || '_exists_color_size_stock_product');
END $$;

\echo
\echo index_family_2_join_key_first

DO $$
DECLARE
    selected_product_options_table TEXT;
BEGIN
    SELECT product_options_table
    INTO selected_product_options_table
    FROM product_options_exists_rewrite_config;

    EXECUTE format(
        'CREATE INDEX %I ON %I (product_id, color, size, stock_status)',
        'idx_exp_' || selected_product_options_table || '_exists_product_color_size_stock',
        selected_product_options_table
    );
END $$;

ANALYZE :product_options_table;

\echo index_family_2__j1_join_distinct_explain
EXPLAIN (ANALYZE, BUFFERS, VERBOSE)
SELECT DISTINCT p.*
FROM :products_table p
JOIN :product_options_table po
  ON po.product_id = p.id
WHERE p.category_id = 35
  AND p.status = 'ACTIVE'
  AND p.price BETWEEN 10000 AND 100000
  AND po.color = (SELECT common_color FROM product_options_exists_rewrite_config)
  AND po.size = (SELECT common_size FROM product_options_exists_rewrite_config)
  AND po.stock_status = (SELECT common_stock_status FROM product_options_exists_rewrite_config)
ORDER BY p.created_at DESC, p.id DESC
LIMIT 50 OFFSET 100;

\echo index_family_2__j1_exists_explain
EXPLAIN (ANALYZE, BUFFERS, VERBOSE)
SELECT p.*
FROM :products_table p
WHERE p.category_id = 35
  AND p.status = 'ACTIVE'
  AND p.price BETWEEN 10000 AND 100000
  AND EXISTS (
      SELECT 1
      FROM :product_options_table po
      WHERE po.product_id = p.id
        AND po.color = (SELECT common_color FROM product_options_exists_rewrite_config)
        AND po.size = (SELECT common_size FROM product_options_exists_rewrite_config)
        AND po.stock_status = (SELECT common_stock_status FROM product_options_exists_rewrite_config)
  )
ORDER BY p.created_at DESC, p.id DESC
LIMIT 50 OFFSET 100;

\echo index_family_2__j2_join_distinct_explain
EXPLAIN (ANALYZE, BUFFERS, VERBOSE)
SELECT DISTINCT p.*
FROM :products_table p
JOIN :product_options_table po
  ON po.product_id = p.id
WHERE p.category_id = 35
  AND p.brand_id = 543
  AND p.status = 'ACTIVE'
  AND p.price BETWEEN 10000 AND 100000
  AND po.color = (SELECT common_color FROM product_options_exists_rewrite_config)
  AND po.size = (SELECT common_size FROM product_options_exists_rewrite_config)
  AND po.stock_status = (SELECT common_stock_status FROM product_options_exists_rewrite_config)
ORDER BY p.price ASC, p.id ASC
LIMIT 50 OFFSET 100;

\echo index_family_2__j2_exists_explain
EXPLAIN (ANALYZE, BUFFERS, VERBOSE)
SELECT p.*
FROM :products_table p
WHERE p.category_id = 35
  AND p.brand_id = 543
  AND p.status = 'ACTIVE'
  AND p.price BETWEEN 10000 AND 100000
  AND EXISTS (
      SELECT 1
      FROM :product_options_table po
      WHERE po.product_id = p.id
        AND po.color = (SELECT common_color FROM product_options_exists_rewrite_config)
        AND po.size = (SELECT common_size FROM product_options_exists_rewrite_config)
        AND po.stock_status = (SELECT common_stock_status FROM product_options_exists_rewrite_config)
  )
ORDER BY p.price ASC, p.id ASC
LIMIT 50 OFFSET 100;

\echo index_family_2__j3_join_distinct_explain
EXPLAIN (ANALYZE, BUFFERS, VERBOSE)
SELECT DISTINCT p.*
FROM :products_table p
JOIN :product_options_table po
  ON po.product_id = p.id
WHERE p.category_id = 35
  AND p.status = 'ACTIVE'
  AND po.color = (SELECT common_color FROM product_options_exists_rewrite_config)
  AND po.size = (SELECT common_size FROM product_options_exists_rewrite_config)
  AND po.stock_status = (SELECT common_stock_status FROM product_options_exists_rewrite_config)
ORDER BY p.review_count DESC, p.id DESC
LIMIT 50 OFFSET 100;

\echo index_family_2__j3_exists_explain
EXPLAIN (ANALYZE, BUFFERS, VERBOSE)
SELECT p.*
FROM :products_table p
WHERE p.category_id = 35
  AND p.status = 'ACTIVE'
  AND EXISTS (
      SELECT 1
      FROM :product_options_table po
      WHERE po.product_id = p.id
        AND po.color = (SELECT common_color FROM product_options_exists_rewrite_config)
        AND po.size = (SELECT common_size FROM product_options_exists_rewrite_config)
        AND po.stock_status = (SELECT common_stock_status FROM product_options_exists_rewrite_config)
  )
ORDER BY p.review_count DESC, p.id DESC
LIMIT 50 OFFSET 100;

\echo index_family_2__j4_join_distinct_explain
EXPLAIN (ANALYZE, BUFFERS, VERBOSE)
SELECT DISTINCT p.*
FROM :products_table p
JOIN :product_options_table po
  ON po.product_id = p.id
WHERE p.category_id = 35
  AND p.status = 'ACTIVE'
  AND p.price BETWEEN 10000 AND 100000
  AND po.color = (SELECT common_color FROM product_options_exists_rewrite_config)
  AND po.size = (SELECT common_size FROM product_options_exists_rewrite_config)
  AND po.stock_status = (SELECT common_stock_status FROM product_options_exists_rewrite_config)
ORDER BY p.created_at DESC, p.id DESC
LIMIT 50 OFFSET 10000;

\echo index_family_2__j4_exists_explain
EXPLAIN (ANALYZE, BUFFERS, VERBOSE)
SELECT p.*
FROM :products_table p
WHERE p.category_id = 35
  AND p.status = 'ACTIVE'
  AND p.price BETWEEN 10000 AND 100000
  AND EXISTS (
      SELECT 1
      FROM :product_options_table po
      WHERE po.product_id = p.id
        AND po.color = (SELECT common_color FROM product_options_exists_rewrite_config)
        AND po.size = (SELECT common_size FROM product_options_exists_rewrite_config)
        AND po.stock_status = (SELECT common_stock_status FROM product_options_exists_rewrite_config)
  )
ORDER BY p.created_at DESC, p.id DESC
LIMIT 50 OFFSET 10000;

\echo index_family_2__j5_join_distinct_explain
EXPLAIN (ANALYZE, BUFFERS, VERBOSE)
SELECT DISTINCT p.*
FROM :products_table p
JOIN :product_options_table po
  ON po.product_id = p.id
WHERE p.status = 'ACTIVE'
  AND po.color = (SELECT common_color FROM product_options_exists_rewrite_config)
  AND po.size = (SELECT common_size FROM product_options_exists_rewrite_config)
  AND po.stock_status = (SELECT common_stock_status FROM product_options_exists_rewrite_config)
ORDER BY p.created_at DESC, p.id DESC
LIMIT 50 OFFSET 100;

\echo index_family_2__j5_exists_explain
EXPLAIN (ANALYZE, BUFFERS, VERBOSE)
SELECT p.*
FROM :products_table p
WHERE p.status = 'ACTIVE'
  AND EXISTS (
      SELECT 1
      FROM :product_options_table po
      WHERE po.product_id = p.id
        AND po.color = (SELECT common_color FROM product_options_exists_rewrite_config)
        AND po.size = (SELECT common_size FROM product_options_exists_rewrite_config)
        AND po.stock_status = (SELECT common_stock_status FROM product_options_exists_rewrite_config)
  )
ORDER BY p.created_at DESC, p.id DESC
LIMIT 50 OFFSET 100;

\echo index_family_2__j6_option_selectivity_control
SELECT
    control_case,
    color,
    size,
    stock_status,
    joined_option_rows,
    distinct_product_count,
    ROUND(joined_option_rows::NUMERIC / NULLIF(distinct_product_count, 0), 4) AS option_rows_per_distinct_product
FROM (
    SELECT 'common_global' AS control_case, cfg.common_color AS color, cfg.common_size AS size, cfg.common_stock_status AS stock_status, COUNT(*) AS joined_option_rows, COUNT(DISTINCT p.id) AS distinct_product_count
    FROM :products_table p JOIN :product_options_table po ON po.product_id = p.id CROSS JOIN product_options_exists_rewrite_config cfg
    WHERE po.color = cfg.common_color AND po.size = cfg.common_size AND po.stock_status = cfg.common_stock_status
    GROUP BY cfg.common_color, cfg.common_size, cfg.common_stock_status
    UNION ALL
    SELECT 'less_common_global', cfg.less_common_color, cfg.less_common_size, cfg.less_common_stock_status, COUNT(*), COUNT(DISTINCT p.id)
    FROM :products_table p JOIN :product_options_table po ON po.product_id = p.id CROSS JOIN product_options_exists_rewrite_config cfg
    WHERE po.color = cfg.less_common_color AND po.size = cfg.less_common_size AND po.stock_status = cfg.less_common_stock_status
    GROUP BY cfg.less_common_color, cfg.less_common_size, cfg.less_common_stock_status
    UNION ALL
    SELECT 'common_q1_shape', cfg.common_color, cfg.common_size, cfg.common_stock_status, COUNT(*), COUNT(DISTINCT p.id)
    FROM :products_table p JOIN :product_options_table po ON po.product_id = p.id CROSS JOIN product_options_exists_rewrite_config cfg
    WHERE p.category_id = 35 AND p.status = 'ACTIVE' AND p.price BETWEEN 10000 AND 100000
      AND po.color = cfg.common_color AND po.size = cfg.common_size AND po.stock_status = cfg.common_stock_status
    GROUP BY cfg.common_color, cfg.common_size, cfg.common_stock_status
    UNION ALL
    SELECT 'common_q2_shape', cfg.common_color, cfg.common_size, cfg.common_stock_status, COUNT(*), COUNT(DISTINCT p.id)
    FROM :products_table p JOIN :product_options_table po ON po.product_id = p.id CROSS JOIN product_options_exists_rewrite_config cfg
    WHERE p.category_id = 35 AND p.brand_id = 543 AND p.status = 'ACTIVE' AND p.price BETWEEN 10000 AND 100000
      AND po.color = cfg.common_color AND po.size = cfg.common_size AND po.stock_status = cfg.common_stock_status
    GROUP BY cfg.common_color, cfg.common_size, cfg.common_stock_status
    UNION ALL
    SELECT 'less_common_q1_shape', cfg.less_common_color, cfg.less_common_size, cfg.less_common_stock_status, COUNT(*), COUNT(DISTINCT p.id)
    FROM :products_table p JOIN :product_options_table po ON po.product_id = p.id CROSS JOIN product_options_exists_rewrite_config cfg
    WHERE p.category_id = 35 AND p.status = 'ACTIVE' AND p.price BETWEEN 10000 AND 100000
      AND po.color = cfg.less_common_color AND po.size = cfg.less_common_size AND po.stock_status = cfg.less_common_stock_status
    GROUP BY cfg.less_common_color, cfg.less_common_size, cfg.less_common_stock_status
    UNION ALL
    SELECT 'less_common_q2_shape', cfg.less_common_color, cfg.less_common_size, cfg.less_common_stock_status, COUNT(*), COUNT(DISTINCT p.id)
    FROM :products_table p JOIN :product_options_table po ON po.product_id = p.id CROSS JOIN product_options_exists_rewrite_config cfg
    WHERE p.category_id = 35 AND p.brand_id = 543 AND p.status = 'ACTIVE' AND p.price BETWEEN 10000 AND 100000
      AND po.color = cfg.less_common_color AND po.size = cfg.less_common_size AND po.stock_status = cfg.less_common_stock_status
    GROUP BY cfg.less_common_color, cfg.less_common_size, cfg.less_common_stock_status
) controls
ORDER BY control_case;

DO $$
DECLARE
    selected_product_options_table TEXT;
BEGIN
    SELECT product_options_table INTO selected_product_options_table FROM product_options_exists_rewrite_config;
    EXECUTE format('DROP INDEX IF EXISTS %I', 'idx_exp_' || selected_product_options_table || '_exists_product_color_size_stock');
END $$;

\echo
\echo verify_no_experiment_indexes_remain

SELECT tablename, indexname
FROM pg_indexes
WHERE schemaname = 'public'
  AND indexname LIKE 'idx_exp_%'
ORDER BY tablename, indexname;
