\set ON_ERROR_STOP on

BEGIN;

DELETE FROM product_options_moderate_skew
WHERE product_id BETWEEN -19002999 AND -19002000;

DELETE FROM products
WHERE id BETWEEN -19002999 AND -19002000;

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
        -19002004,
        19004,
        75,
        943,
        'ACTIVE',
        11900,
        4.70,
        301,
        TIMESTAMP '2026-05-02 11:00:00',
        TIMESTAMP '2026-05-02 11:00:00'
    ),
    (
        -19002003,
        19003,
        75,
        943,
        'SOLD_OUT',
        20900,
        3.95,
        22,
        TIMESTAMP '2026-05-02 11:01:00',
        TIMESTAMP '2026-05-02 11:02:00'
    ),
    (
        -19002002,
        19002,
        75,
        943,
        'ACTIVE',
        32900,
        4.20,
        87,
        TIMESTAMP '2026-05-02 11:03:00',
        TIMESTAMP '2026-05-02 11:04:00'
    ),
    (
        -19002001,
        19001,
        75,
        943,
        'ACTIVE',
        45900,
        4.42,
        151,
        TIMESTAMP '2026-05-02 11:05:00',
        TIMESTAMP '2026-05-02 11:10:00'
    );

INSERT INTO product_options_moderate_skew (
    id,
    product_id,
    color,
    size,
    stock_status
)
VALUES
    (-1900200401, -19002004, 'BLACK', 'S', 'IN_STOCK'),
    (-1900200402, -19002004, 'WHITE', 'M', 'IN_STOCK'),
    (-1900200301, -19002003, 'GRAY', 'M', 'LOW_STOCK'),
    (-1900200101, -19002001, 'BLUE', 'FREE', 'IN_STOCK');

COMMIT;

SELECT jsonb_build_object(
    'preparedProducts', 4,
    'preparedOptions', 4,
    'sourceFilter', 'products.id BETWEEN -19002999 AND -19002000'
)::TEXT;
