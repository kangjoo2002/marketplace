\set ON_ERROR_STOP on

-- Prepares controlled source rows for the lag/fallback/rollback operations
-- smoke. The runner calls this only after PostgreSQL readiness and
-- OpenSearch health have both been established.
--
-- This file intentionally cleans only experiment-owned negative product IDs
-- and outbox rows namespaced by this experiment's smokeRun values.

WITH namespaced_outbox AS (
    DELETE FROM search_outbox
    WHERE payload->>'smokeRun' IN (
        'opensearch-lag-fallback-rollback-normal',
        'opensearch-lag-fallback-rollback-backlog'
    )
    RETURNING id
),
deleted_options AS (
    DELETE FROM product_options_moderate_skew
    WHERE product_id IN (
        -21002001, -21002002, -21002003, -21002004, -21002005,
        -21002011, -21002012, -21002013
    )
    RETURNING id
),
deleted_products AS (
    DELETE FROM products
    WHERE id IN (
        -21002001, -21002002, -21002003, -21002004, -21002005,
        -21002011, -21002012, -21002013
    )
    RETURNING id
),
inserted_products AS (
    INSERT INTO products (
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
    )
    VALUES
        (-21002001, 21001, 75, 943, 'ACTIVE', 21900, 4.51, 310, TIMESTAMP '2026-05-02 15:00:01', TIMESTAMP '2026-05-02 15:00:01'),
        (-21002002, 21002, 75, 943, 'ACTIVE', 22900, 4.52, 320, TIMESTAMP '2026-05-02 15:00:02', TIMESTAMP '2026-05-02 15:00:02'),
        (-21002003, 21003, 75, 943, 'ACTIVE', 23900, 4.53, 330, TIMESTAMP '2026-05-02 15:00:03', TIMESTAMP '2026-05-02 15:00:03'),
        (-21002004, 21004, 75, 943, 'ACTIVE', 24900, 4.54, 340, TIMESTAMP '2026-05-02 15:00:04', TIMESTAMP '2026-05-02 15:00:04'),
        (-21002005, 21005, 75, 943, 'ACTIVE', 25900, 4.55, 350, TIMESTAMP '2026-05-02 15:00:05', TIMESTAMP '2026-05-02 15:00:05'),
        (-21002011, 21011, 76, 944, 'ACTIVE', 31900, 4.61, 410, TIMESTAMP '2026-05-02 15:01:01', TIMESTAMP '2026-05-02 15:01:01'),
        (-21002012, 21012, 76, 944, 'ACTIVE', 32900, 4.62, 420, TIMESTAMP '2026-05-02 15:01:02', TIMESTAMP '2026-05-02 15:01:02'),
        (-21002013, 21013, 76, 944, 'ACTIVE', 33900, 4.63, 430, TIMESTAMP '2026-05-02 15:01:03', TIMESTAMP '2026-05-02 15:01:03')
    RETURNING id
),
inserted_options AS (
    INSERT INTO product_options_moderate_skew (
        id,
        product_id,
        color,
        size,
        stock_status
    )
    VALUES
        (-2100200101, -21002001, 'BLACK', 'M', 'IN_STOCK'),
        (-2100200201, -21002002, 'BLACK', 'M', 'IN_STOCK'),
        (-2100200301, -21002003, 'BLACK', 'M', 'IN_STOCK'),
        (-2100200401, -21002004, 'BLACK', 'M', 'IN_STOCK'),
        (-2100200501, -21002005, 'BLACK', 'M', 'IN_STOCK'),
        (-2100201101, -21002011, 'RED', 'S', 'IN_STOCK'),
        (-2100201201, -21002012, 'RED', 'S', 'IN_STOCK'),
        (-2100201301, -21002013, 'RED', 'S', 'IN_STOCK')
    RETURNING id
)
SELECT jsonb_build_object(
    'deletedOutboxRows', (SELECT COUNT(*) FROM namespaced_outbox),
    'deletedOptionRows', (SELECT COUNT(*) FROM deleted_options),
    'deletedProductRows', (SELECT COUNT(*) FROM deleted_products),
    'insertedProductRows', (SELECT COUNT(*) FROM inserted_products),
    'insertedOptionRows', (SELECT COUNT(*) FROM inserted_options),
    'normalSourceProductCount', 5,
    'backlogSourceProductCount', 3
)::TEXT;
