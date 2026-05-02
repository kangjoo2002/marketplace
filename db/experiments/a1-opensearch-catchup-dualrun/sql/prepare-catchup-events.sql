\set ON_ERROR_STOP on

BEGIN;

DELETE FROM search_outbox
WHERE aggregate_type = 'PRODUCT'
  AND (
      aggregate_id BETWEEN -20002999 AND -20002000
      OR payload->>'smokeRun' = 'opensearch-catchup-dualrun'
  );

DELETE FROM product_options_moderate_skew
WHERE product_id BETWEEN -20002999 AND -20002000;

DELETE FROM products
WHERE id BETWEEN -20002999 AND -20002000;

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
    (
        -20002004,
        20004,
        75,
        943,
        'ACTIVE',
        11900,
        4.70,
        301,
        TIMESTAMP '2026-05-02 12:00:00',
        TIMESTAMP '2026-05-02 12:00:00'
    ),
    (
        -20002003,
        20003,
        75,
        943,
        'ACTIVE',
        20900,
        3.95,
        22,
        TIMESTAMP '2026-05-02 12:01:00',
        TIMESTAMP '2026-05-02 12:02:00'
    ),
    (
        -20002002,
        20002,
        75,
        943,
        'ACTIVE',
        32900,
        4.20,
        87,
        TIMESTAMP '2026-05-02 12:03:00',
        TIMESTAMP '2026-05-02 12:04:00'
    ),
    (
        -20002001,
        20001,
        75,
        943,
        'ACTIVE',
        45900,
        4.42,
        151,
        TIMESTAMP '2026-05-02 12:05:00',
        TIMESTAMP '2026-05-02 12:10:00'
    );

INSERT INTO product_options_moderate_skew (
    id,
    product_id,
    color,
    size,
    stock_status
)
VALUES
    (-2000200401, -20002004, 'BLACK', 'S', 'IN_STOCK'),
    (-2000200402, -20002004, 'WHITE', 'M', 'IN_STOCK'),
    (-2000200301, -20002003, 'GRAY', 'M', 'LOW_STOCK'),
    (-2000200201, -20002002, 'BLUE', 'FREE', 'IN_STOCK'),
    (-2000200101, -20002001, 'NAVY', 'M', 'IN_STOCK');

COMMIT;

SELECT jsonb_build_object(
    'preparedBaselineProducts', 4,
    'preparedBaselineOptions', 5,
    'sourceFilter', 'products.id BETWEEN -20002999 AND -20002000 AND products.status = ''ACTIVE''',
    'smokeRun', 'opensearch-catchup-dualrun'
)::TEXT;
