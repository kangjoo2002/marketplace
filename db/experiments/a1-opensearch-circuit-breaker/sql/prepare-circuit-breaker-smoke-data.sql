\set ON_ERROR_STOP on

-- Controlled local smoke data for the OpenSearch read-path circuit breaker.
-- The app smoke points the DB path at products + product_options_moderate_skew
-- so fallback assertions stay small and namespaced.

WITH deleted_options AS (
    DELETE FROM product_options_moderate_skew
    WHERE product_id IN (-23002001, -23002002, -23002003)
    RETURNING id
),
deleted_products AS (
    DELETE FROM products
    WHERE id IN (-23002001, -23002002, -23002003)
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
        (-23002001, 23001, 23075, 23943, 'ACTIVE', 21900, 4.51, 310, TIMESTAMP '2026-05-02 17:00:01', TIMESTAMP '2026-05-02 17:00:01'),
        (-23002002, 23002, 23075, 23943, 'ACTIVE', 22900, 4.52, 320, TIMESTAMP '2026-05-02 17:00:02', TIMESTAMP '2026-05-02 17:00:02'),
        (-23002003, 23003, 23075, 23943, 'ACTIVE', 23900, 4.53, 330, TIMESTAMP '2026-05-02 17:00:03', TIMESTAMP '2026-05-02 17:00:03')
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
        (-2300200101, -23002001, 'BLACK', 'M', 'IN_STOCK'),
        (-2300200201, -23002002, 'BLACK', 'M', 'IN_STOCK'),
        (-2300200301, -23002003, 'BLACK', 'M', 'IN_STOCK')
    RETURNING id
)
SELECT jsonb_build_object(
    'deletedProductRows', (SELECT COUNT(*) FROM deleted_products),
    'deletedOptionRows', (SELECT COUNT(*) FROM deleted_options),
    'insertedProductRows', (SELECT COUNT(*) FROM inserted_products),
    'insertedOptionRows', (SELECT COUNT(*) FROM inserted_options),
    'smokeProductCount', 3
)::TEXT;
