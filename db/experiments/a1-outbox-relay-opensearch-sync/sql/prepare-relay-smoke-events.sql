\set ON_ERROR_STOP on

BEGIN;

DELETE FROM search_outbox
WHERE aggregate_type = 'PRODUCT'
  AND (
      aggregate_id BETWEEN -18002999 AND -18002000
      OR payload->>'smokeRun' IN (
          'outbox-relay-opensearch-sync',
          'outbox-relay-opensearch-sync-failure',
          'outbox-relay-opensearch-sync-cleanup'
      )
  );

DELETE FROM product_options_moderate_skew
WHERE product_id BETWEEN -18002999 AND -18002000;

DELETE FROM products
WHERE id BETWEEN -18002999 AND -18002000;

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
        -18002001,
        18001,
        75,
        943,
        'ACTIVE',
        45900,
        4.42,
        151,
        TIMESTAMP '2026-05-02 09:00:00',
        TIMESTAMP '2026-05-02 09:10:00'
    ),
    (
        -18002002,
        18002,
        75,
        943,
        'ACTIVE',
        27900,
        4.11,
        42,
        TIMESTAMP '2026-05-02 09:00:00',
        TIMESTAMP '2026-05-02 09:00:00'
    ),
    (
        -18002003,
        18003,
        75,
        943,
        'ACTIVE',
        19900,
        3.95,
        9,
        TIMESTAMP '2026-05-02 09:00:00',
        TIMESTAMP '2026-05-02 09:00:00'
    );

INSERT INTO product_options_moderate_skew (
    id,
    product_id,
    color,
    size,
    stock_status
)
VALUES
    (-1800200101, -18002001, 'BLACK', 'S', 'IN_STOCK'),
    (-1800200102, -18002001, 'WHITE', 'M', 'IN_STOCK'),
    (-1800200201, -18002002, 'BLUE', 'FREE', 'IN_STOCK'),
    (-1800200301, -18002003, 'GRAY', 'M', 'LOW_STOCK');

INSERT INTO search_outbox (
    aggregate_type,
    aggregate_id,
    event_type,
    payload,
    created_at,
    updated_at
)
VALUES
    (
        'PRODUCT',
        -18002001,
        'PRODUCT_CREATED',
        jsonb_build_object(
            'productId', -18002001,
            'eventType', 'PRODUCT_CREATED',
            'sourceUpdatedAt', '2026-05-02T09:00:00',
            'tombstone', false,
            'smokeRun', 'outbox-relay-opensearch-sync'
        ),
        now(),
        now()
    ),
    (
        'PRODUCT',
        -18002001,
        'PRODUCT_UPDATED',
        jsonb_build_object(
            'productId', -18002001,
            'eventType', 'PRODUCT_UPDATED',
            'sourceUpdatedAt', '2026-05-02T09:10:00',
            'tombstone', false,
            'smokeRun', 'outbox-relay-opensearch-sync'
        ),
        now(),
        now()
    ),
    (
        'PRODUCT',
        -18002002,
        'PRODUCT_CREATED',
        jsonb_build_object(
            'productId', -18002002,
            'eventType', 'PRODUCT_CREATED',
            'sourceUpdatedAt', '2026-05-02T09:00:00',
            'tombstone', false,
            'smokeRun', 'outbox-relay-opensearch-sync'
        ),
        now(),
        now()
    ),
    (
        'PRODUCT',
        -18002003,
        'PRODUCT_CREATED',
        jsonb_build_object(
            'productId', -18002003,
            'eventType', 'PRODUCT_CREATED',
            'sourceUpdatedAt', '2026-05-02T09:00:00',
            'tombstone', false,
            'smokeRun', 'outbox-relay-opensearch-sync-failure'
        ),
        now(),
        now()
    );

COMMIT;

SELECT jsonb_build_object(
    'preparedProducts', 3,
    'preparedRelayEvents', 3,
    'preparedFailureEvents', 1,
    'smokeRun', 'outbox-relay-opensearch-sync'
)::TEXT;
