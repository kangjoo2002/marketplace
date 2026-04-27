\set ON_ERROR_STOP on
\timing on
\pset pager off

-- A-1c products + product_options EXISTS OFFSET vs keyset pagination experiment.
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
-- This script creates experiment-only indexes and drops them before exit.

\if :{?products_table}
\else
\set products_table 'products_moderate_skew'
\endif

\if :{?product_options_table}
\else
\set product_options_table 'product_options_moderate_skew'
\endif

\echo experiment_start

CREATE TEMP TABLE join_keyset_pagination_config (
    products_table TEXT NOT NULL,
    product_options_table TEXT NOT NULL,
    common_color TEXT NOT NULL,
    common_size TEXT NOT NULL,
    common_stock_status TEXT NOT NULL,
    less_common_color TEXT NOT NULL,
    less_common_size TEXT NOT NULL,
    less_common_stock_status TEXT NOT NULL
);

INSERT INTO join_keyset_pagination_config (
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
    FROM join_keyset_pagination_config;

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

CREATE TEMP TABLE join_keyset_pagination_cursors (
    index_family TEXT NOT NULL,
    case_name TEXT NOT NULL,
    cursor_created_at TIMESTAMP NULL,
    cursor_id BIGINT NULL,
    cursor_note TEXT NOT NULL,
    PRIMARY KEY (index_family, case_name)
);

CREATE TEMP TABLE join_keyset_pagination_equivalence_results (
    index_family TEXT NOT NULL,
    case_name TEXT NOT NULL,
    offset_page_count BIGINT NOT NULL,
    keyset_page_count BIGINT NOT NULL,
    ids_match BOOLEAN NOT NULL,
    check_note TEXT NOT NULL
);

\echo
\echo target_table_info

SELECT
    'A-1c product_options EXISTS OFFSET vs keyset pagination' AS experiment,
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
FROM join_keyset_pagination_config;

SELECT :'products_table' AS products_table, COUNT(*) AS product_count
FROM :products_table;

SELECT :'product_options_table' AS product_options_table, COUNT(*) AS product_options_count
FROM :product_options_table;

\echo
\echo cleanup_existing_join_keyset_experiment_indexes_before_start

DO $$
DECLARE
    selected_products_table TEXT;
    selected_product_options_table TEXT;
BEGIN
    SELECT products_table, product_options_table
    INTO selected_products_table, selected_product_options_table
    FROM join_keyset_pagination_config;

    EXECUTE format('DROP INDEX IF EXISTS %I', 'idx_exp_' || selected_products_table || '_jk_active_created');
    EXECUTE format('DROP INDEX IF EXISTS %I', 'idx_exp_' || replace(selected_product_options_table, 'product_options_', 'po_') || '_jk_opt_first');
    EXECUTE format('DROP INDEX IF EXISTS %I', 'idx_exp_' || replace(selected_product_options_table, 'product_options_', 'po_') || '_jk_join_first');
END $$;

\echo
\echo create_supporting_products_pagination_index

DO $$
DECLARE
    selected_products_table TEXT;
BEGIN
    SELECT products_table
    INTO selected_products_table
    FROM join_keyset_pagination_config;

    EXECUTE format(
        'CREATE INDEX %I ON %I (created_at DESC, id DESC) WHERE status = ''ACTIVE''',
        'idx_exp_' || selected_products_table || '_jk_active_created',
        selected_products_table
    );
END $$;

ANALYZE :products_table;

\echo
\echo index_family_1_option_filter_first

DO $$
DECLARE
    selected_product_options_table TEXT;
BEGIN
    SELECT product_options_table
    INTO selected_product_options_table
    FROM join_keyset_pagination_config;

    EXECUTE format(
        'CREATE INDEX %I ON %I (color, size, stock_status, product_id)',
        'idx_exp_' || replace(selected_product_options_table, 'product_options_', 'po_') || '_jk_opt_first',
        selected_product_options_table
    );
END $$;

ANALYZE :product_options_table;

\echo index_family_1__cursor_derivation
\echo cursor_derivation_is_experiment_setup_only_not_keyset_read_path

INSERT INTO join_keyset_pagination_cursors (index_family, case_name, cursor_created_at, cursor_id, cursor_note)
SELECT
    'option_filter_first',
    'k1_selective_less_common_offset_100',
    c.created_at,
    c.id,
    'Derived from OFFSET 99 LIMIT 1 for local reproducibility only'
FROM (SELECT 1) seed
LEFT JOIN LATERAL (
    SELECT p.created_at, p.id
    FROM :products_table p
    WHERE p.category_id = 35
      AND p.status = 'ACTIVE'
      AND p.price BETWEEN 10000 AND 100000
      AND EXISTS (
          SELECT 1
          FROM :product_options_table po
          WHERE po.product_id = p.id
            AND po.color = (SELECT less_common_color FROM join_keyset_pagination_config)
            AND po.size = (SELECT less_common_size FROM join_keyset_pagination_config)
            AND po.stock_status = (SELECT less_common_stock_status FROM join_keyset_pagination_config)
      )
    ORDER BY p.created_at DESC, p.id DESC
    LIMIT 1 OFFSET 99
) c ON TRUE;

INSERT INTO join_keyset_pagination_cursors (index_family, case_name, cursor_created_at, cursor_id, cursor_note)
SELECT
    'option_filter_first',
    'k2_broader_common_offset_100',
    c.created_at,
    c.id,
    'Derived from OFFSET 99 LIMIT 1 for local reproducibility only'
FROM (SELECT 1) seed
LEFT JOIN LATERAL (
    SELECT p.created_at, p.id
    FROM :products_table p
    WHERE p.status = 'ACTIVE'
      AND EXISTS (
          SELECT 1
          FROM :product_options_table po
          WHERE po.product_id = p.id
            AND po.color = (SELECT common_color FROM join_keyset_pagination_config)
            AND po.size = (SELECT common_size FROM join_keyset_pagination_config)
            AND po.stock_status = (SELECT common_stock_status FROM join_keyset_pagination_config)
      )
    ORDER BY p.created_at DESC, p.id DESC
    LIMIT 1 OFFSET 99
) c ON TRUE;

INSERT INTO join_keyset_pagination_cursors (index_family, case_name, cursor_created_at, cursor_id, cursor_note)
SELECT
    'option_filter_first',
    'k3_deep_common_offset_10000',
    c.created_at,
    c.id,
    'Derived from OFFSET 9999 LIMIT 1 for local reproducibility only'
FROM (SELECT 1) seed
LEFT JOIN LATERAL (
    SELECT p.created_at, p.id
    FROM :products_table p
    WHERE p.status = 'ACTIVE'
      AND EXISTS (
          SELECT 1
          FROM :product_options_table po
          WHERE po.product_id = p.id
            AND po.color = (SELECT common_color FROM join_keyset_pagination_config)
            AND po.size = (SELECT common_size FROM join_keyset_pagination_config)
            AND po.stock_status = (SELECT common_stock_status FROM join_keyset_pagination_config)
      )
    ORDER BY p.created_at DESC, p.id DESC
    LIMIT 1 OFFSET 9999
) c ON TRUE;

SELECT *
FROM join_keyset_pagination_cursors
WHERE index_family = 'option_filter_first'
ORDER BY case_name;

\echo index_family_1__k1_offset_exists_explain
EXPLAIN (ANALYZE, BUFFERS, VERBOSE)
SELECT p.id, p.seller_id, p.category_id, p.brand_id, p.status, p.price, p.rating, p.review_count, p.created_at, p.updated_at
FROM :products_table p
WHERE p.category_id = 35
  AND p.status = 'ACTIVE'
  AND p.price BETWEEN 10000 AND 100000
  AND EXISTS (
      SELECT 1
      FROM :product_options_table po
      WHERE po.product_id = p.id
        AND po.color = (SELECT less_common_color FROM join_keyset_pagination_config)
        AND po.size = (SELECT less_common_size FROM join_keyset_pagination_config)
        AND po.stock_status = (SELECT less_common_stock_status FROM join_keyset_pagination_config)
  )
ORDER BY p.created_at DESC, p.id DESC
LIMIT 50 OFFSET 100;

\echo index_family_1__k1_keyset_exists_explain
EXPLAIN (ANALYZE, BUFFERS, VERBOSE)
SELECT p.id, p.seller_id, p.category_id, p.brand_id, p.status, p.price, p.rating, p.review_count, p.created_at, p.updated_at
FROM :products_table p
CROSS JOIN join_keyset_pagination_cursors c
WHERE c.index_family = 'option_filter_first'
  AND c.case_name = 'k1_selective_less_common_offset_100'
  AND c.cursor_created_at IS NOT NULL
  AND p.category_id = 35
  AND p.status = 'ACTIVE'
  AND p.price BETWEEN 10000 AND 100000
  AND (p.created_at, p.id) < (c.cursor_created_at, c.cursor_id)
  AND EXISTS (
      SELECT 1
      FROM :product_options_table po
      WHERE po.product_id = p.id
        AND po.color = (SELECT less_common_color FROM join_keyset_pagination_config)
        AND po.size = (SELECT less_common_size FROM join_keyset_pagination_config)
        AND po.stock_status = (SELECT less_common_stock_status FROM join_keyset_pagination_config)
  )
ORDER BY p.created_at DESC, p.id DESC
LIMIT 50;

\echo index_family_1__k1_result_equivalence_check
WITH
offset_page AS (
    SELECT row_number() OVER (ORDER BY created_at DESC, id DESC) AS row_number, id
    FROM (
        SELECT p.id, p.created_at
        FROM :products_table p
        WHERE p.category_id = 35
          AND p.status = 'ACTIVE'
          AND p.price BETWEEN 10000 AND 100000
          AND EXISTS (
              SELECT 1
              FROM :product_options_table po
              WHERE po.product_id = p.id
                AND po.color = (SELECT less_common_color FROM join_keyset_pagination_config)
                AND po.size = (SELECT less_common_size FROM join_keyset_pagination_config)
                AND po.stock_status = (SELECT less_common_stock_status FROM join_keyset_pagination_config)
          )
        ORDER BY p.created_at DESC, p.id DESC
        LIMIT 50 OFFSET 100
    ) page
),
keyset_page AS (
    SELECT row_number() OVER (ORDER BY created_at DESC, id DESC) AS row_number, id
    FROM (
        SELECT p.id, p.created_at
        FROM :products_table p
        CROSS JOIN join_keyset_pagination_cursors c
        WHERE c.index_family = 'option_filter_first'
          AND c.case_name = 'k1_selective_less_common_offset_100'
          AND c.cursor_created_at IS NOT NULL
          AND p.category_id = 35
          AND p.status = 'ACTIVE'
          AND p.price BETWEEN 10000 AND 100000
          AND (p.created_at, p.id) < (c.cursor_created_at, c.cursor_id)
          AND EXISTS (
              SELECT 1
              FROM :product_options_table po
              WHERE po.product_id = p.id
                AND po.color = (SELECT less_common_color FROM join_keyset_pagination_config)
                AND po.size = (SELECT less_common_size FROM join_keyset_pagination_config)
                AND po.stock_status = (SELECT less_common_stock_status FROM join_keyset_pagination_config)
          )
        ORDER BY p.created_at DESC, p.id DESC
        LIMIT 50
    ) page
),
offset_ids AS (
    SELECT COALESCE(array_agg(id ORDER BY row_number), ARRAY[]::bigint[]) AS ids FROM offset_page
),
keyset_ids AS (
    SELECT COALESCE(array_agg(id ORDER BY row_number), ARRAY[]::bigint[]) AS ids FROM keyset_page
)
INSERT INTO join_keyset_pagination_equivalence_results
SELECT
    'option_filter_first',
    'k1_selective_less_common_offset_100',
    (SELECT COUNT(*) FROM offset_page),
    (SELECT COUNT(*) FROM keyset_page),
    (SELECT ids FROM offset_ids) = (SELECT ids FROM keyset_ids),
    'Correctness sanity check only; not a performance benchmark';

SELECT *
FROM join_keyset_pagination_equivalence_results
WHERE index_family = 'option_filter_first'
  AND case_name = 'k1_selective_less_common_offset_100';

\echo index_family_1__k2_offset_exists_explain
EXPLAIN (ANALYZE, BUFFERS, VERBOSE)
SELECT p.id, p.seller_id, p.category_id, p.brand_id, p.status, p.price, p.rating, p.review_count, p.created_at, p.updated_at
FROM :products_table p
WHERE p.status = 'ACTIVE'
  AND EXISTS (
      SELECT 1
      FROM :product_options_table po
      WHERE po.product_id = p.id
        AND po.color = (SELECT common_color FROM join_keyset_pagination_config)
        AND po.size = (SELECT common_size FROM join_keyset_pagination_config)
        AND po.stock_status = (SELECT common_stock_status FROM join_keyset_pagination_config)
  )
ORDER BY p.created_at DESC, p.id DESC
LIMIT 50 OFFSET 100;

\echo index_family_1__k2_keyset_exists_explain
EXPLAIN (ANALYZE, BUFFERS, VERBOSE)
SELECT p.id, p.seller_id, p.category_id, p.brand_id, p.status, p.price, p.rating, p.review_count, p.created_at, p.updated_at
FROM :products_table p
CROSS JOIN join_keyset_pagination_cursors c
WHERE c.index_family = 'option_filter_first'
  AND c.case_name = 'k2_broader_common_offset_100'
  AND c.cursor_created_at IS NOT NULL
  AND p.status = 'ACTIVE'
  AND (p.created_at, p.id) < (c.cursor_created_at, c.cursor_id)
  AND EXISTS (
      SELECT 1
      FROM :product_options_table po
      WHERE po.product_id = p.id
        AND po.color = (SELECT common_color FROM join_keyset_pagination_config)
        AND po.size = (SELECT common_size FROM join_keyset_pagination_config)
        AND po.stock_status = (SELECT common_stock_status FROM join_keyset_pagination_config)
  )
ORDER BY p.created_at DESC, p.id DESC
LIMIT 50;

\echo index_family_1__k2_result_equivalence_check
WITH
offset_page AS (
    SELECT row_number() OVER (ORDER BY created_at DESC, id DESC) AS row_number, id
    FROM (
        SELECT p.id, p.created_at
        FROM :products_table p
        WHERE p.status = 'ACTIVE'
          AND EXISTS (
              SELECT 1
              FROM :product_options_table po
              WHERE po.product_id = p.id
                AND po.color = (SELECT common_color FROM join_keyset_pagination_config)
                AND po.size = (SELECT common_size FROM join_keyset_pagination_config)
                AND po.stock_status = (SELECT common_stock_status FROM join_keyset_pagination_config)
          )
        ORDER BY p.created_at DESC, p.id DESC
        LIMIT 50 OFFSET 100
    ) page
),
keyset_page AS (
    SELECT row_number() OVER (ORDER BY created_at DESC, id DESC) AS row_number, id
    FROM (
        SELECT p.id, p.created_at
        FROM :products_table p
        CROSS JOIN join_keyset_pagination_cursors c
        WHERE c.index_family = 'option_filter_first'
          AND c.case_name = 'k2_broader_common_offset_100'
          AND c.cursor_created_at IS NOT NULL
          AND p.status = 'ACTIVE'
          AND (p.created_at, p.id) < (c.cursor_created_at, c.cursor_id)
          AND EXISTS (
              SELECT 1
              FROM :product_options_table po
              WHERE po.product_id = p.id
                AND po.color = (SELECT common_color FROM join_keyset_pagination_config)
                AND po.size = (SELECT common_size FROM join_keyset_pagination_config)
                AND po.stock_status = (SELECT common_stock_status FROM join_keyset_pagination_config)
          )
        ORDER BY p.created_at DESC, p.id DESC
        LIMIT 50
    ) page
),
offset_ids AS (
    SELECT COALESCE(array_agg(id ORDER BY row_number), ARRAY[]::bigint[]) AS ids FROM offset_page
),
keyset_ids AS (
    SELECT COALESCE(array_agg(id ORDER BY row_number), ARRAY[]::bigint[]) AS ids FROM keyset_page
)
INSERT INTO join_keyset_pagination_equivalence_results
SELECT
    'option_filter_first',
    'k2_broader_common_offset_100',
    (SELECT COUNT(*) FROM offset_page),
    (SELECT COUNT(*) FROM keyset_page),
    (SELECT ids FROM offset_ids) = (SELECT ids FROM keyset_ids),
    'Correctness sanity check only; not a performance benchmark';

SELECT *
FROM join_keyset_pagination_equivalence_results
WHERE index_family = 'option_filter_first'
  AND case_name = 'k2_broader_common_offset_100';

\echo index_family_1__k3_offset_exists_explain
EXPLAIN (ANALYZE, BUFFERS, VERBOSE)
SELECT p.id, p.seller_id, p.category_id, p.brand_id, p.status, p.price, p.rating, p.review_count, p.created_at, p.updated_at
FROM :products_table p
WHERE p.status = 'ACTIVE'
  AND EXISTS (
      SELECT 1
      FROM :product_options_table po
      WHERE po.product_id = p.id
        AND po.color = (SELECT common_color FROM join_keyset_pagination_config)
        AND po.size = (SELECT common_size FROM join_keyset_pagination_config)
        AND po.stock_status = (SELECT common_stock_status FROM join_keyset_pagination_config)
  )
ORDER BY p.created_at DESC, p.id DESC
LIMIT 50 OFFSET 10000;

\echo index_family_1__k3_keyset_exists_explain
EXPLAIN (ANALYZE, BUFFERS, VERBOSE)
SELECT p.id, p.seller_id, p.category_id, p.brand_id, p.status, p.price, p.rating, p.review_count, p.created_at, p.updated_at
FROM :products_table p
CROSS JOIN join_keyset_pagination_cursors c
WHERE c.index_family = 'option_filter_first'
  AND c.case_name = 'k3_deep_common_offset_10000'
  AND c.cursor_created_at IS NOT NULL
  AND p.status = 'ACTIVE'
  AND (p.created_at, p.id) < (c.cursor_created_at, c.cursor_id)
  AND EXISTS (
      SELECT 1
      FROM :product_options_table po
      WHERE po.product_id = p.id
        AND po.color = (SELECT common_color FROM join_keyset_pagination_config)
        AND po.size = (SELECT common_size FROM join_keyset_pagination_config)
        AND po.stock_status = (SELECT common_stock_status FROM join_keyset_pagination_config)
  )
ORDER BY p.created_at DESC, p.id DESC
LIMIT 50;

\echo index_family_1__k3_result_equivalence_check
WITH
offset_page AS (
    SELECT row_number() OVER (ORDER BY created_at DESC, id DESC) AS row_number, id
    FROM (
        SELECT p.id, p.created_at
        FROM :products_table p
        WHERE p.status = 'ACTIVE'
          AND EXISTS (
              SELECT 1
              FROM :product_options_table po
              WHERE po.product_id = p.id
                AND po.color = (SELECT common_color FROM join_keyset_pagination_config)
                AND po.size = (SELECT common_size FROM join_keyset_pagination_config)
                AND po.stock_status = (SELECT common_stock_status FROM join_keyset_pagination_config)
          )
        ORDER BY p.created_at DESC, p.id DESC
        LIMIT 50 OFFSET 10000
    ) page
),
keyset_page AS (
    SELECT row_number() OVER (ORDER BY created_at DESC, id DESC) AS row_number, id
    FROM (
        SELECT p.id, p.created_at
        FROM :products_table p
        CROSS JOIN join_keyset_pagination_cursors c
        WHERE c.index_family = 'option_filter_first'
          AND c.case_name = 'k3_deep_common_offset_10000'
          AND c.cursor_created_at IS NOT NULL
          AND p.status = 'ACTIVE'
          AND (p.created_at, p.id) < (c.cursor_created_at, c.cursor_id)
          AND EXISTS (
              SELECT 1
              FROM :product_options_table po
              WHERE po.product_id = p.id
                AND po.color = (SELECT common_color FROM join_keyset_pagination_config)
                AND po.size = (SELECT common_size FROM join_keyset_pagination_config)
                AND po.stock_status = (SELECT common_stock_status FROM join_keyset_pagination_config)
          )
        ORDER BY p.created_at DESC, p.id DESC
        LIMIT 50
    ) page
),
offset_ids AS (
    SELECT COALESCE(array_agg(id ORDER BY row_number), ARRAY[]::bigint[]) AS ids FROM offset_page
),
keyset_ids AS (
    SELECT COALESCE(array_agg(id ORDER BY row_number), ARRAY[]::bigint[]) AS ids FROM keyset_page
)
INSERT INTO join_keyset_pagination_equivalence_results
SELECT
    'option_filter_first',
    'k3_deep_common_offset_10000',
    (SELECT COUNT(*) FROM offset_page),
    (SELECT COUNT(*) FROM keyset_page),
    (SELECT ids FROM offset_ids) = (SELECT ids FROM keyset_ids),
    'Correctness sanity check only; not a performance benchmark';

SELECT *
FROM join_keyset_pagination_equivalence_results
WHERE index_family = 'option_filter_first'
  AND case_name = 'k3_deep_common_offset_10000';

DO $$
DECLARE
    selected_product_options_table TEXT;
BEGIN
    SELECT product_options_table
    INTO selected_product_options_table
    FROM join_keyset_pagination_config;

    EXECUTE format('DROP INDEX IF EXISTS %I', 'idx_exp_' || replace(selected_product_options_table, 'product_options_', 'po_') || '_jk_opt_first');
END $$;

\echo
\echo index_family_2_join_key_first

DO $$
DECLARE
    selected_product_options_table TEXT;
BEGIN
    SELECT product_options_table
    INTO selected_product_options_table
    FROM join_keyset_pagination_config;

    EXECUTE format(
        'CREATE INDEX %I ON %I (product_id, color, size, stock_status)',
        'idx_exp_' || replace(selected_product_options_table, 'product_options_', 'po_') || '_jk_join_first',
        selected_product_options_table
    );
END $$;

ANALYZE :product_options_table;

\echo index_family_2__cursor_derivation
\echo cursor_derivation_is_experiment_setup_only_not_keyset_read_path

INSERT INTO join_keyset_pagination_cursors (index_family, case_name, cursor_created_at, cursor_id, cursor_note)
SELECT
    'join_key_first',
    'k1_selective_less_common_offset_100',
    c.created_at,
    c.id,
    'Derived from OFFSET 99 LIMIT 1 for local reproducibility only'
FROM (SELECT 1) seed
LEFT JOIN LATERAL (
    SELECT p.created_at, p.id
    FROM :products_table p
    WHERE p.category_id = 35
      AND p.status = 'ACTIVE'
      AND p.price BETWEEN 10000 AND 100000
      AND EXISTS (
          SELECT 1
          FROM :product_options_table po
          WHERE po.product_id = p.id
            AND po.color = (SELECT less_common_color FROM join_keyset_pagination_config)
            AND po.size = (SELECT less_common_size FROM join_keyset_pagination_config)
            AND po.stock_status = (SELECT less_common_stock_status FROM join_keyset_pagination_config)
      )
    ORDER BY p.created_at DESC, p.id DESC
    LIMIT 1 OFFSET 99
) c ON TRUE;

INSERT INTO join_keyset_pagination_cursors (index_family, case_name, cursor_created_at, cursor_id, cursor_note)
SELECT
    'join_key_first',
    'k2_broader_common_offset_100',
    c.created_at,
    c.id,
    'Derived from OFFSET 99 LIMIT 1 for local reproducibility only'
FROM (SELECT 1) seed
LEFT JOIN LATERAL (
    SELECT p.created_at, p.id
    FROM :products_table p
    WHERE p.status = 'ACTIVE'
      AND EXISTS (
          SELECT 1
          FROM :product_options_table po
          WHERE po.product_id = p.id
            AND po.color = (SELECT common_color FROM join_keyset_pagination_config)
            AND po.size = (SELECT common_size FROM join_keyset_pagination_config)
            AND po.stock_status = (SELECT common_stock_status FROM join_keyset_pagination_config)
      )
    ORDER BY p.created_at DESC, p.id DESC
    LIMIT 1 OFFSET 99
) c ON TRUE;

INSERT INTO join_keyset_pagination_cursors (index_family, case_name, cursor_created_at, cursor_id, cursor_note)
SELECT
    'join_key_first',
    'k3_deep_common_offset_10000',
    c.created_at,
    c.id,
    'Derived from OFFSET 9999 LIMIT 1 for local reproducibility only'
FROM (SELECT 1) seed
LEFT JOIN LATERAL (
    SELECT p.created_at, p.id
    FROM :products_table p
    WHERE p.status = 'ACTIVE'
      AND EXISTS (
          SELECT 1
          FROM :product_options_table po
          WHERE po.product_id = p.id
            AND po.color = (SELECT common_color FROM join_keyset_pagination_config)
            AND po.size = (SELECT common_size FROM join_keyset_pagination_config)
            AND po.stock_status = (SELECT common_stock_status FROM join_keyset_pagination_config)
      )
    ORDER BY p.created_at DESC, p.id DESC
    LIMIT 1 OFFSET 9999
) c ON TRUE;

SELECT *
FROM join_keyset_pagination_cursors
WHERE index_family = 'join_key_first'
ORDER BY case_name;

\echo index_family_2__k1_offset_exists_explain
EXPLAIN (ANALYZE, BUFFERS, VERBOSE)
SELECT p.id, p.seller_id, p.category_id, p.brand_id, p.status, p.price, p.rating, p.review_count, p.created_at, p.updated_at
FROM :products_table p
WHERE p.category_id = 35
  AND p.status = 'ACTIVE'
  AND p.price BETWEEN 10000 AND 100000
  AND EXISTS (
      SELECT 1
      FROM :product_options_table po
      WHERE po.product_id = p.id
        AND po.color = (SELECT less_common_color FROM join_keyset_pagination_config)
        AND po.size = (SELECT less_common_size FROM join_keyset_pagination_config)
        AND po.stock_status = (SELECT less_common_stock_status FROM join_keyset_pagination_config)
  )
ORDER BY p.created_at DESC, p.id DESC
LIMIT 50 OFFSET 100;

\echo index_family_2__k1_keyset_exists_explain
EXPLAIN (ANALYZE, BUFFERS, VERBOSE)
SELECT p.id, p.seller_id, p.category_id, p.brand_id, p.status, p.price, p.rating, p.review_count, p.created_at, p.updated_at
FROM :products_table p
CROSS JOIN join_keyset_pagination_cursors c
WHERE c.index_family = 'join_key_first'
  AND c.case_name = 'k1_selective_less_common_offset_100'
  AND c.cursor_created_at IS NOT NULL
  AND p.category_id = 35
  AND p.status = 'ACTIVE'
  AND p.price BETWEEN 10000 AND 100000
  AND (p.created_at, p.id) < (c.cursor_created_at, c.cursor_id)
  AND EXISTS (
      SELECT 1
      FROM :product_options_table po
      WHERE po.product_id = p.id
        AND po.color = (SELECT less_common_color FROM join_keyset_pagination_config)
        AND po.size = (SELECT less_common_size FROM join_keyset_pagination_config)
        AND po.stock_status = (SELECT less_common_stock_status FROM join_keyset_pagination_config)
  )
ORDER BY p.created_at DESC, p.id DESC
LIMIT 50;

\echo index_family_2__k1_result_equivalence_check
WITH
offset_page AS (
    SELECT row_number() OVER (ORDER BY created_at DESC, id DESC) AS row_number, id
    FROM (
        SELECT p.id, p.created_at
        FROM :products_table p
        WHERE p.category_id = 35
          AND p.status = 'ACTIVE'
          AND p.price BETWEEN 10000 AND 100000
          AND EXISTS (
              SELECT 1
              FROM :product_options_table po
              WHERE po.product_id = p.id
                AND po.color = (SELECT less_common_color FROM join_keyset_pagination_config)
                AND po.size = (SELECT less_common_size FROM join_keyset_pagination_config)
                AND po.stock_status = (SELECT less_common_stock_status FROM join_keyset_pagination_config)
          )
        ORDER BY p.created_at DESC, p.id DESC
        LIMIT 50 OFFSET 100
    ) page
),
keyset_page AS (
    SELECT row_number() OVER (ORDER BY created_at DESC, id DESC) AS row_number, id
    FROM (
        SELECT p.id, p.created_at
        FROM :products_table p
        CROSS JOIN join_keyset_pagination_cursors c
        WHERE c.index_family = 'join_key_first'
          AND c.case_name = 'k1_selective_less_common_offset_100'
          AND c.cursor_created_at IS NOT NULL
          AND p.category_id = 35
          AND p.status = 'ACTIVE'
          AND p.price BETWEEN 10000 AND 100000
          AND (p.created_at, p.id) < (c.cursor_created_at, c.cursor_id)
          AND EXISTS (
              SELECT 1
              FROM :product_options_table po
              WHERE po.product_id = p.id
                AND po.color = (SELECT less_common_color FROM join_keyset_pagination_config)
                AND po.size = (SELECT less_common_size FROM join_keyset_pagination_config)
                AND po.stock_status = (SELECT less_common_stock_status FROM join_keyset_pagination_config)
          )
        ORDER BY p.created_at DESC, p.id DESC
        LIMIT 50
    ) page
),
offset_ids AS (
    SELECT COALESCE(array_agg(id ORDER BY row_number), ARRAY[]::bigint[]) AS ids FROM offset_page
),
keyset_ids AS (
    SELECT COALESCE(array_agg(id ORDER BY row_number), ARRAY[]::bigint[]) AS ids FROM keyset_page
)
INSERT INTO join_keyset_pagination_equivalence_results
SELECT
    'join_key_first',
    'k1_selective_less_common_offset_100',
    (SELECT COUNT(*) FROM offset_page),
    (SELECT COUNT(*) FROM keyset_page),
    (SELECT ids FROM offset_ids) = (SELECT ids FROM keyset_ids),
    'Correctness sanity check only; not a performance benchmark';

SELECT *
FROM join_keyset_pagination_equivalence_results
WHERE index_family = 'join_key_first'
  AND case_name = 'k1_selective_less_common_offset_100';

\echo index_family_2__k2_offset_exists_explain
EXPLAIN (ANALYZE, BUFFERS, VERBOSE)
SELECT p.id, p.seller_id, p.category_id, p.brand_id, p.status, p.price, p.rating, p.review_count, p.created_at, p.updated_at
FROM :products_table p
WHERE p.status = 'ACTIVE'
  AND EXISTS (
      SELECT 1
      FROM :product_options_table po
      WHERE po.product_id = p.id
        AND po.color = (SELECT common_color FROM join_keyset_pagination_config)
        AND po.size = (SELECT common_size FROM join_keyset_pagination_config)
        AND po.stock_status = (SELECT common_stock_status FROM join_keyset_pagination_config)
  )
ORDER BY p.created_at DESC, p.id DESC
LIMIT 50 OFFSET 100;

\echo index_family_2__k2_keyset_exists_explain
EXPLAIN (ANALYZE, BUFFERS, VERBOSE)
SELECT p.id, p.seller_id, p.category_id, p.brand_id, p.status, p.price, p.rating, p.review_count, p.created_at, p.updated_at
FROM :products_table p
CROSS JOIN join_keyset_pagination_cursors c
WHERE c.index_family = 'join_key_first'
  AND c.case_name = 'k2_broader_common_offset_100'
  AND c.cursor_created_at IS NOT NULL
  AND p.status = 'ACTIVE'
  AND (p.created_at, p.id) < (c.cursor_created_at, c.cursor_id)
  AND EXISTS (
      SELECT 1
      FROM :product_options_table po
      WHERE po.product_id = p.id
        AND po.color = (SELECT common_color FROM join_keyset_pagination_config)
        AND po.size = (SELECT common_size FROM join_keyset_pagination_config)
        AND po.stock_status = (SELECT common_stock_status FROM join_keyset_pagination_config)
  )
ORDER BY p.created_at DESC, p.id DESC
LIMIT 50;

\echo index_family_2__k2_result_equivalence_check
WITH
offset_page AS (
    SELECT row_number() OVER (ORDER BY created_at DESC, id DESC) AS row_number, id
    FROM (
        SELECT p.id, p.created_at
        FROM :products_table p
        WHERE p.status = 'ACTIVE'
          AND EXISTS (
              SELECT 1
              FROM :product_options_table po
              WHERE po.product_id = p.id
                AND po.color = (SELECT common_color FROM join_keyset_pagination_config)
                AND po.size = (SELECT common_size FROM join_keyset_pagination_config)
                AND po.stock_status = (SELECT common_stock_status FROM join_keyset_pagination_config)
          )
        ORDER BY p.created_at DESC, p.id DESC
        LIMIT 50 OFFSET 100
    ) page
),
keyset_page AS (
    SELECT row_number() OVER (ORDER BY created_at DESC, id DESC) AS row_number, id
    FROM (
        SELECT p.id, p.created_at
        FROM :products_table p
        CROSS JOIN join_keyset_pagination_cursors c
        WHERE c.index_family = 'join_key_first'
          AND c.case_name = 'k2_broader_common_offset_100'
          AND c.cursor_created_at IS NOT NULL
          AND p.status = 'ACTIVE'
          AND (p.created_at, p.id) < (c.cursor_created_at, c.cursor_id)
          AND EXISTS (
              SELECT 1
              FROM :product_options_table po
              WHERE po.product_id = p.id
                AND po.color = (SELECT common_color FROM join_keyset_pagination_config)
                AND po.size = (SELECT common_size FROM join_keyset_pagination_config)
                AND po.stock_status = (SELECT common_stock_status FROM join_keyset_pagination_config)
          )
        ORDER BY p.created_at DESC, p.id DESC
        LIMIT 50
    ) page
),
offset_ids AS (
    SELECT COALESCE(array_agg(id ORDER BY row_number), ARRAY[]::bigint[]) AS ids FROM offset_page
),
keyset_ids AS (
    SELECT COALESCE(array_agg(id ORDER BY row_number), ARRAY[]::bigint[]) AS ids FROM keyset_page
)
INSERT INTO join_keyset_pagination_equivalence_results
SELECT
    'join_key_first',
    'k2_broader_common_offset_100',
    (SELECT COUNT(*) FROM offset_page),
    (SELECT COUNT(*) FROM keyset_page),
    (SELECT ids FROM offset_ids) = (SELECT ids FROM keyset_ids),
    'Correctness sanity check only; not a performance benchmark';

SELECT *
FROM join_keyset_pagination_equivalence_results
WHERE index_family = 'join_key_first'
  AND case_name = 'k2_broader_common_offset_100';

\echo index_family_2__k3_offset_exists_explain
EXPLAIN (ANALYZE, BUFFERS, VERBOSE)
SELECT p.id, p.seller_id, p.category_id, p.brand_id, p.status, p.price, p.rating, p.review_count, p.created_at, p.updated_at
FROM :products_table p
WHERE p.status = 'ACTIVE'
  AND EXISTS (
      SELECT 1
      FROM :product_options_table po
      WHERE po.product_id = p.id
        AND po.color = (SELECT common_color FROM join_keyset_pagination_config)
        AND po.size = (SELECT common_size FROM join_keyset_pagination_config)
        AND po.stock_status = (SELECT common_stock_status FROM join_keyset_pagination_config)
  )
ORDER BY p.created_at DESC, p.id DESC
LIMIT 50 OFFSET 10000;

\echo index_family_2__k3_keyset_exists_explain
EXPLAIN (ANALYZE, BUFFERS, VERBOSE)
SELECT p.id, p.seller_id, p.category_id, p.brand_id, p.status, p.price, p.rating, p.review_count, p.created_at, p.updated_at
FROM :products_table p
CROSS JOIN join_keyset_pagination_cursors c
WHERE c.index_family = 'join_key_first'
  AND c.case_name = 'k3_deep_common_offset_10000'
  AND c.cursor_created_at IS NOT NULL
  AND p.status = 'ACTIVE'
  AND (p.created_at, p.id) < (c.cursor_created_at, c.cursor_id)
  AND EXISTS (
      SELECT 1
      FROM :product_options_table po
      WHERE po.product_id = p.id
        AND po.color = (SELECT common_color FROM join_keyset_pagination_config)
        AND po.size = (SELECT common_size FROM join_keyset_pagination_config)
        AND po.stock_status = (SELECT common_stock_status FROM join_keyset_pagination_config)
  )
ORDER BY p.created_at DESC, p.id DESC
LIMIT 50;

\echo index_family_2__k3_result_equivalence_check
WITH
offset_page AS (
    SELECT row_number() OVER (ORDER BY created_at DESC, id DESC) AS row_number, id
    FROM (
        SELECT p.id, p.created_at
        FROM :products_table p
        WHERE p.status = 'ACTIVE'
          AND EXISTS (
              SELECT 1
              FROM :product_options_table po
              WHERE po.product_id = p.id
                AND po.color = (SELECT common_color FROM join_keyset_pagination_config)
                AND po.size = (SELECT common_size FROM join_keyset_pagination_config)
                AND po.stock_status = (SELECT common_stock_status FROM join_keyset_pagination_config)
          )
        ORDER BY p.created_at DESC, p.id DESC
        LIMIT 50 OFFSET 10000
    ) page
),
keyset_page AS (
    SELECT row_number() OVER (ORDER BY created_at DESC, id DESC) AS row_number, id
    FROM (
        SELECT p.id, p.created_at
        FROM :products_table p
        CROSS JOIN join_keyset_pagination_cursors c
        WHERE c.index_family = 'join_key_first'
          AND c.case_name = 'k3_deep_common_offset_10000'
          AND c.cursor_created_at IS NOT NULL
          AND p.status = 'ACTIVE'
          AND (p.created_at, p.id) < (c.cursor_created_at, c.cursor_id)
          AND EXISTS (
              SELECT 1
              FROM :product_options_table po
              WHERE po.product_id = p.id
                AND po.color = (SELECT common_color FROM join_keyset_pagination_config)
                AND po.size = (SELECT common_size FROM join_keyset_pagination_config)
                AND po.stock_status = (SELECT common_stock_status FROM join_keyset_pagination_config)
          )
        ORDER BY p.created_at DESC, p.id DESC
        LIMIT 50
    ) page
),
offset_ids AS (
    SELECT COALESCE(array_agg(id ORDER BY row_number), ARRAY[]::bigint[]) AS ids FROM offset_page
),
keyset_ids AS (
    SELECT COALESCE(array_agg(id ORDER BY row_number), ARRAY[]::bigint[]) AS ids FROM keyset_page
)
INSERT INTO join_keyset_pagination_equivalence_results
SELECT
    'join_key_first',
    'k3_deep_common_offset_10000',
    (SELECT COUNT(*) FROM offset_page),
    (SELECT COUNT(*) FROM keyset_page),
    (SELECT ids FROM offset_ids) = (SELECT ids FROM keyset_ids),
    'Correctness sanity check only; not a performance benchmark';

SELECT *
FROM join_keyset_pagination_equivalence_results
WHERE index_family = 'join_key_first'
  AND case_name = 'k3_deep_common_offset_10000';

\echo
\echo all_result_equivalence_checks

SELECT *
FROM join_keyset_pagination_equivalence_results
ORDER BY index_family, case_name;

DO $$
BEGIN
    IF EXISTS (
        SELECT 1
        FROM join_keyset_pagination_equivalence_results
        WHERE ids_match IS NOT TRUE
    ) THEN
        RAISE EXCEPTION 'OFFSET/keyset result equivalence check failed. Inspect join_keyset_pagination_equivalence_results output above.';
    END IF;
END $$;

\echo
\echo cleanup_experiment_indexes

DO $$
DECLARE
    selected_products_table TEXT;
    selected_product_options_table TEXT;
BEGIN
    SELECT products_table, product_options_table
    INTO selected_products_table, selected_product_options_table
    FROM join_keyset_pagination_config;

    EXECUTE format('DROP INDEX IF EXISTS %I', 'idx_exp_' || replace(selected_product_options_table, 'product_options_', 'po_') || '_jk_join_first');
    EXECUTE format('DROP INDEX IF EXISTS %I', 'idx_exp_' || replace(selected_product_options_table, 'product_options_', 'po_') || '_jk_opt_first');
    EXECUTE format('DROP INDEX IF EXISTS %I', 'idx_exp_' || selected_products_table || '_jk_active_created');
END $$;

ANALYZE :products_table;
ANALYZE :product_options_table;

\echo
\echo verify_no_experiment_indexes_remain

SELECT tablename, indexname
FROM pg_indexes
WHERE schemaname = 'public'
  AND indexname LIKE 'idx_exp_%'
ORDER BY tablename, indexname;
