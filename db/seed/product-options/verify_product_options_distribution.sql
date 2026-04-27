\set ON_ERROR_STOP on
\timing on

-- Verification report for synthetic product_options seed profiles.
--
-- Supported psql variable:
--   -v seed_profile=uniform
--   -v seed_profile=moderate-skew
--   -v seed_profile=high-skew
--
-- If seed_profile is omitted, moderate-skew is used.

\if :{?seed_profile}
\else
\set seed_profile 'moderate-skew'
\endif

CREATE TEMP TABLE verify_product_options_config (
    profile TEXT NOT NULL,
    products_table TEXT NOT NULL,
    options_table TEXT NOT NULL
);

INSERT INTO verify_product_options_config (profile, products_table, options_table)
SELECT
    :'seed_profile',
    CASE :'seed_profile'
        WHEN 'uniform' THEN 'products_uniform'
        WHEN 'moderate-skew' THEN 'products_moderate_skew'
        WHEN 'high-skew' THEN 'products_high_skew'
        ELSE ''
    END,
    CASE :'seed_profile'
        WHEN 'uniform' THEN 'product_options_uniform'
        WHEN 'moderate-skew' THEN 'product_options_moderate_skew'
        WHEN 'high-skew' THEN 'product_options_high_skew'
        ELSE ''
    END;

DO $$
DECLARE
    selected_profile TEXT;
    selected_products_table TEXT;
    selected_options_table TEXT;
BEGIN
    SELECT profile, products_table, options_table
    INTO selected_profile, selected_products_table, selected_options_table
    FROM verify_product_options_config;

    IF selected_profile NOT IN ('uniform', 'moderate-skew', 'high-skew') THEN
        RAISE EXCEPTION
            'Unsupported seed_profile: %. Supported profiles: uniform, moderate-skew, high-skew',
            selected_profile;
    END IF;

    IF to_regclass(selected_products_table) IS NULL THEN
        RAISE EXCEPTION 'products table does not exist: %', selected_products_table;
    END IF;

    IF to_regclass(selected_options_table) IS NULL THEN
        RAISE EXCEPTION 'product_options table does not exist: %', selected_options_table;
    END IF;
END $$;

SELECT
    profile,
    products_table,
    options_table,
    'Foreign keys are intentionally omitted in this local benchmark schema; orphan rows are verified below.' AS schema_note
FROM verify_product_options_config;

SELECT format('SELECT %L AS products_table, COUNT(*) AS product_count FROM %I', products_table, products_table)
FROM verify_product_options_config
\gexec

SELECT format('SELECT %L AS options_table, COUNT(*) AS product_options_count FROM %I', options_table, options_table)
FROM verify_product_options_config
\gexec

DROP TABLE IF EXISTS verify_product_options_fanout;

SELECT format($sql$
    CREATE TEMP TABLE verify_product_options_fanout AS
    SELECT product_id, COUNT(*) AS options_per_product
    FROM %I
    GROUP BY product_id
$sql$, options_table)
FROM verify_product_options_config
\gexec

CREATE INDEX verify_product_options_fanout_product_id_idx
ON verify_product_options_fanout (product_id);

ANALYZE verify_product_options_fanout;

SELECT COUNT(*) AS distinct_product_id_count
FROM verify_product_options_fanout;

SELECT
    MIN(options_per_product) AS min_options_per_product,
    ROUND(AVG(options_per_product)::NUMERIC, 4) AS avg_options_per_product,
    MAX(options_per_product) AS max_options_per_product
FROM verify_product_options_fanout;

SELECT format($sql$
    SELECT COUNT(*) AS products_with_zero_options
    FROM %I p
    LEFT JOIN verify_product_options_fanout f
      ON f.product_id = p.id
    WHERE f.product_id IS NULL
$sql$, products_table)
FROM verify_product_options_config
\gexec

SELECT format($sql$
    SELECT COUNT(*) AS orphan_product_options_rows
    FROM %I po
    LEFT JOIN %I p
      ON p.id = po.product_id
    WHERE p.id IS NULL
$sql$, options_table, products_table)
FROM verify_product_options_config
\gexec

SELECT
    options_per_product,
    COUNT(*) AS product_count,
    ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER (), 4) AS percentage
FROM verify_product_options_fanout
GROUP BY options_per_product
ORDER BY options_per_product;

SELECT format($sql$
    SELECT
        color,
        COUNT(*) AS row_count,
        ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER (), 4) AS percentage
    FROM %I
    GROUP BY color
    ORDER BY row_count DESC, color
$sql$, options_table)
FROM verify_product_options_config
\gexec

SELECT format($sql$
    SELECT
        size,
        COUNT(*) AS row_count,
        ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER (), 4) AS percentage
    FROM %I
    GROUP BY size
    ORDER BY row_count DESC, size
$sql$, options_table)
FROM verify_product_options_config
\gexec

SELECT format($sql$
    SELECT
        stock_status,
        COUNT(*) AS row_count,
        ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER (), 4) AS percentage
    FROM %I
    GROUP BY stock_status
    ORDER BY row_count DESC, stock_status
$sql$, options_table)
FROM verify_product_options_config
\gexec

SELECT format($sql$
    SELECT
        color,
        size,
        COUNT(*) AS row_count,
        ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER (), 4) AS percentage
    FROM %I
    GROUP BY color, size
    ORDER BY row_count DESC, color, size
$sql$, options_table)
FROM verify_product_options_config
\gexec

SELECT format($sql$
    SELECT
        color,
        size,
        stock_status,
        COUNT(*) AS row_count,
        ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER (), 4) AS percentage
    FROM %I
    GROUP BY color, size, stock_status
    ORDER BY row_count DESC, color, size, stock_status
$sql$, options_table)
FROM verify_product_options_config
\gexec

SELECT format($sql$
    SELECT
        p.category_id,
        po.color,
        po.size,
        po.stock_status,
        COUNT(*) AS option_row_count,
        COUNT(DISTINCT p.id) AS distinct_product_count
    FROM %I p
    JOIN %I po
      ON po.product_id = p.id
    WHERE p.category_id = 35
      AND p.status = 'ACTIVE'
      AND p.price BETWEEN 10000 AND 100000
    GROUP BY p.category_id, po.color, po.size, po.stock_status
    ORDER BY option_row_count DESC, po.color, po.size, po.stock_status
    LIMIT 30
$sql$, products_table, options_table)
FROM verify_product_options_config
\gexec

SELECT format($sql$
    SELECT
        p.category_id,
        p.brand_id,
        po.color,
        po.size,
        po.stock_status,
        COUNT(*) AS option_row_count,
        COUNT(DISTINCT p.id) AS distinct_product_count
    FROM %I p
    JOIN %I po
      ON po.product_id = p.id
    WHERE p.category_id = 35
      AND p.brand_id = 543
      AND p.status = 'ACTIVE'
      AND p.price BETWEEN 10000 AND 100000
    GROUP BY p.category_id, p.brand_id, po.color, po.size, po.stock_status
    ORDER BY option_row_count DESC, po.color, po.size, po.stock_status
    LIMIT 30
$sql$, products_table, options_table)
FROM verify_product_options_config
\gexec
