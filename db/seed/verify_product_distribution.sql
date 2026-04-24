\set ON_ERROR_STOP on
\timing on

\if :{?target_table}
\else
\set target_table 'products_active'
\endif

CREATE TEMP TABLE verify_product_distribution_config (
    target_table TEXT NOT NULL
);

INSERT INTO verify_product_distribution_config (target_table)
VALUES (:'target_table');

DO $$
DECLARE
    selected_target_table TEXT;
BEGIN
    SELECT target_table
    INTO selected_target_table
    FROM verify_product_distribution_config;

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

SELECT format('SELECT %L AS target_table, COUNT(*) AS total_product_count FROM %I', target_table, target_table)
FROM verify_product_distribution_config
\gexec

SELECT format($sql$
    SELECT
        status,
        COUNT(*) AS row_count,
        ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER (), 2) AS percentage
    FROM %I
    GROUP BY status
    ORDER BY status
$sql$, target_table)
FROM verify_product_distribution_config
\gexec

SELECT format('SELECT COUNT(DISTINCT category_id) AS category_count FROM %I', target_table)
FROM verify_product_distribution_config
\gexec

SELECT format('SELECT COUNT(DISTINCT brand_id) AS brand_count FROM %I', target_table)
FROM verify_product_distribution_config
\gexec

SELECT format('SELECT COUNT(DISTINCT seller_id) AS seller_count FROM %I', target_table)
FROM verify_product_distribution_config
\gexec

SELECT format($sql$
    WITH total AS (
        SELECT COUNT(*) AS row_count FROM %1$I
    ),
    ranked AS (
        SELECT category_id, COUNT(*) AS row_count
        FROM %1$I
        GROUP BY category_id
        ORDER BY row_count DESC, category_id
        LIMIT 20
    )
    SELECT
        category_id,
        ranked.row_count,
        ROUND(ranked.row_count * 100.0 / total.row_count, 4) AS percentage
    FROM ranked
    CROSS JOIN total
    ORDER BY ranked.row_count DESC, category_id
$sql$, target_table)
FROM verify_product_distribution_config
\gexec

SELECT format($sql$
    WITH total AS (
        SELECT COUNT(*) AS row_count FROM %1$I
    ),
    ranked AS (
        SELECT brand_id, COUNT(*) AS row_count
        FROM %1$I
        GROUP BY brand_id
        ORDER BY row_count DESC, brand_id
        LIMIT 20
    )
    SELECT
        brand_id,
        ranked.row_count,
        ROUND(ranked.row_count * 100.0 / total.row_count, 4) AS percentage
    FROM ranked
    CROSS JOIN total
    ORDER BY ranked.row_count DESC, brand_id
$sql$, target_table)
FROM verify_product_distribution_config
\gexec

SELECT format($sql$
    WITH total AS (
        SELECT COUNT(*) AS row_count FROM %1$I
    ),
    ranked AS (
        SELECT seller_id, COUNT(*) AS row_count
        FROM %1$I
        GROUP BY seller_id
        ORDER BY row_count DESC, seller_id
        LIMIT 20
    )
    SELECT
        seller_id,
        ranked.row_count,
        ROUND(ranked.row_count * 100.0 / total.row_count, 4) AS percentage
    FROM ranked
    CROSS JOIN total
    ORDER BY ranked.row_count DESC, seller_id
$sql$, target_table)
FROM verify_product_distribution_config
\gexec

SELECT format($sql$
    SELECT COUNT(*) AS category_brand_combination_count
    FROM (
        SELECT category_id, brand_id
        FROM %I
        GROUP BY category_id, brand_id
    ) AS category_brand_pairs
$sql$, target_table)
FROM verify_product_distribution_config
\gexec

SELECT format($sql$
    WITH total AS (
        SELECT COUNT(*) AS row_count FROM %1$I
    ),
    ranked AS (
        SELECT category_id, brand_id, COUNT(*) AS row_count
        FROM %1$I
        GROUP BY category_id, brand_id
        ORDER BY row_count DESC, category_id, brand_id
        LIMIT 20
    )
    SELECT
        category_id,
        brand_id,
        ranked.row_count,
        ROUND(ranked.row_count * 100.0 / total.row_count, 4) AS percentage
    FROM ranked
    CROSS JOIN total
    ORDER BY ranked.row_count DESC, category_id, brand_id
$sql$, target_table)
FROM verify_product_distribution_config
\gexec

SELECT format($sql$
    SELECT
        'hot_category_1_hot_brand_1' AS sample_name,
        COUNT(*) AS row_count
    FROM %1$I
    WHERE category_id = 1
      AND brand_id = 1
    UNION ALL
    SELECT
        'cold_category_500_cold_brand_5000' AS sample_name,
        COUNT(*) AS row_count
    FROM %1$I
    WHERE category_id = 500
      AND brand_id = 5000
$sql$, target_table)
FROM verify_product_distribution_config
\gexec

SELECT format($sql$
    SELECT COUNT(*) AS seller_category_combination_count
    FROM (
        SELECT seller_id, category_id
        FROM %I
        GROUP BY seller_id, category_id
    ) AS seller_category_pairs
$sql$, target_table)
FROM verify_product_distribution_config
\gexec

SELECT format($sql$
    SELECT
        CASE
            WHEN price < 10000 THEN '001_1k_to_9,999'
            WHEN price <= 100000 THEN '002_10k_to_100k'
            WHEN price <= 300000 THEN '003_100,001_to_300k'
            WHEN price <= 700000 THEN '004_300,001_to_700k'
            ELSE '005_700,001_to_1m'
        END AS price_bucket,
        COUNT(*) AS row_count,
        ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER (), 2) AS percentage
    FROM %I
    GROUP BY price_bucket
    ORDER BY price_bucket
$sql$, target_table)
FROM verify_product_distribution_config
\gexec

SELECT format($sql$
    SELECT
        CASE
            WHEN review_count <= 20 THEN '001_0_to_20'
            WHEN review_count <= 200 THEN '002_21_to_200'
            WHEN review_count < 1000 THEN '003_201_to_999'
            ELSE '004_1000_plus'
        END AS review_count_bucket,
        COUNT(*) AS row_count,
        ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER (), 2) AS percentage
    FROM %I
    GROUP BY review_count_bucket
    ORDER BY review_count_bucket
$sql$, target_table)
FROM verify_product_distribution_config
\gexec

SELECT format($sql$
    SELECT
        CASE
            WHEN created_at >= LOCALTIMESTAMP - INTERVAL '30 days' THEN '001_recent_30_days'
            WHEN created_at >= LOCALTIMESTAMP - INTERVAL '180 days' THEN '002_31_to_180_days'
            WHEN created_at >= LOCALTIMESTAMP - INTERVAL '365 days' THEN '003_181_to_365_days'
            WHEN created_at >= LOCALTIMESTAMP - INTERVAL '730 days' THEN '004_366_to_730_days'
            ELSE '005_older_than_730_days'
        END AS created_at_bucket,
        COUNT(*) AS row_count,
        ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER (), 2) AS percentage
    FROM %I
    GROUP BY created_at_bucket
    ORDER BY created_at_bucket
$sql$, target_table)
FROM verify_product_distribution_config
\gexec

SELECT format('SELECT MIN(created_at) AS min_created_at, MAX(created_at) AS max_created_at FROM %I', target_table)
FROM verify_product_distribution_config
\gexec

SELECT format('SELECT MIN(updated_at) AS min_updated_at, MAX(updated_at) AS max_updated_at FROM %I', target_table)
FROM verify_product_distribution_config
\gexec

SELECT format('SELECT MIN(rating) AS min_rating, MAX(rating) AS max_rating FROM %I', target_table)
FROM verify_product_distribution_config
\gexec
