\set ON_ERROR_STOP on

BEGIN;

DELETE FROM search_outbox
WHERE aggregate_type = 'PRODUCT'
  AND aggregate_id IN (-17001001, -17001002);

DELETE FROM products
WHERE id IN (-17001001, -17001002);

COMMIT;

BEGIN;

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
VALUES (
    -17001001,
    17001,
    75,
    943,
    'ACTIVE',
    34900,
    4.35,
    128,
    TIMESTAMP '2026-05-01 09:00:00',
    TIMESTAMP '2026-05-01 09:00:00'
);

INSERT INTO search_outbox (
    aggregate_type,
    aggregate_id,
    event_type,
    payload
)
VALUES (
    'PRODUCT',
    -17001001,
    'PRODUCT_CREATED',
    jsonb_build_object(
        'productId', -17001001,
        'eventType', 'PRODUCT_CREATED',
        'sourceUpdatedAt', '2026-05-01T09:00:00',
        'tombstone', false,
        'smokeRun', 'search-outbox-transactional-capture'
    )
);

COMMIT;

BEGIN;

UPDATE products
SET
    price = 35900,
    updated_at = TIMESTAMP '2026-05-01 09:05:00'
WHERE id = -17001001;

INSERT INTO search_outbox (
    aggregate_type,
    aggregate_id,
    event_type,
    payload
)
VALUES (
    'PRODUCT',
    -17001001,
    'PRODUCT_UPDATED',
    jsonb_build_object(
        'productId', -17001001,
        'eventType', 'PRODUCT_UPDATED',
        'sourceUpdatedAt', '2026-05-01T09:05:00',
        'tombstone', false,
        'changedFields', jsonb_build_array('price'),
        'smokeRun', 'search-outbox-transactional-capture'
    )
);

COMMIT;

BEGIN;

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
VALUES (
    -17001002,
    17002,
    75,
    943,
    'ACTIVE',
    19900,
    4.10,
    12,
    TIMESTAMP '2026-05-01 09:10:00',
    TIMESTAMP '2026-05-01 09:10:00'
);

INSERT INTO search_outbox (
    aggregate_type,
    aggregate_id,
    event_type,
    payload
)
VALUES (
    'PRODUCT',
    -17001002,
    'PRODUCT_CREATED',
    jsonb_build_object(
        'productId', -17001002,
        'eventType', 'PRODUCT_CREATED',
        'sourceUpdatedAt', '2026-05-01T09:10:00',
        'tombstone', false,
        'smokeRun', 'search-outbox-transactional-capture-rollback'
    )
);

ROLLBACK;

BEGIN;

UPDATE products
SET
    status = 'DELETED',
    updated_at = TIMESTAMP '2026-05-01 09:15:00'
WHERE id = -17001001;

INSERT INTO search_outbox (
    aggregate_type,
    aggregate_id,
    event_type,
    payload
)
VALUES (
    'PRODUCT',
    -17001001,
    'PRODUCT_STATUS_CHANGED',
    jsonb_build_object(
        'productId', -17001001,
        'eventType', 'PRODUCT_STATUS_CHANGED',
        'sourceUpdatedAt', '2026-05-01T09:15:00',
        'previousStatus', 'ACTIVE',
        'newStatus', 'DELETED',
        'tombstone', false,
        'smokeRun', 'search-outbox-transactional-capture'
    )
);

COMMIT;

DO $$
DECLARE
    committed_product_count INTEGER;
    committed_product_price INTEGER;
    committed_product_status TEXT;
    create_event_count INTEGER;
    update_event_count INTEGER;
    status_change_event_count INTEGER;
    rollback_product_count INTEGER;
    rollback_outbox_count INTEGER;
    pending_event_count INTEGER;
BEGIN
    SELECT COUNT(*), COALESCE(MAX(price), 0), COALESCE(MAX(status), '')
    INTO committed_product_count, committed_product_price, committed_product_status
    FROM products
    WHERE id = -17001001;

    SELECT COUNT(*)
    INTO create_event_count
    FROM search_outbox
    WHERE aggregate_type = 'PRODUCT'
      AND aggregate_id = -17001001
      AND event_type = 'PRODUCT_CREATED'
      AND status = 'PENDING';

    SELECT COUNT(*)
    INTO update_event_count
    FROM search_outbox
    WHERE aggregate_type = 'PRODUCT'
      AND aggregate_id = -17001001
      AND event_type = 'PRODUCT_UPDATED'
      AND status = 'PENDING';

    SELECT COUNT(*)
    INTO status_change_event_count
    FROM search_outbox
    WHERE aggregate_type = 'PRODUCT'
      AND aggregate_id = -17001001
      AND event_type = 'PRODUCT_STATUS_CHANGED'
      AND status = 'PENDING';

    SELECT COUNT(*)
    INTO rollback_product_count
    FROM products
    WHERE id = -17001002;

    SELECT COUNT(*)
    INTO rollback_outbox_count
    FROM search_outbox
    WHERE aggregate_type = 'PRODUCT'
      AND aggregate_id = -17001002;

    SELECT COUNT(*)
    INTO pending_event_count
    FROM search_outbox
    WHERE aggregate_type = 'PRODUCT'
      AND aggregate_id = -17001001
      AND status = 'PENDING';

    IF committed_product_count <> 1 THEN
        RAISE EXCEPTION 'expected committed product count 1, got %', committed_product_count;
    END IF;

    IF committed_product_price <> 35900 THEN
        RAISE EXCEPTION 'expected committed product price 35900, got %', committed_product_price;
    END IF;

    IF committed_product_status <> 'DELETED' THEN
        RAISE EXCEPTION 'expected committed product status DELETED, got %', committed_product_status;
    END IF;

    IF create_event_count <> 1 THEN
        RAISE EXCEPTION 'expected create event count 1, got %', create_event_count;
    END IF;

    IF update_event_count <> 1 THEN
        RAISE EXCEPTION 'expected update event count 1, got %', update_event_count;
    END IF;

    IF status_change_event_count <> 1 THEN
        RAISE EXCEPTION 'expected status-change event count 1, got %', status_change_event_count;
    END IF;

    IF rollback_product_count <> 0 THEN
        RAISE EXCEPTION 'expected rollback product count 0, got %', rollback_product_count;
    END IF;

    IF rollback_outbox_count <> 0 THEN
        RAISE EXCEPTION 'expected rollback outbox count 0, got %', rollback_outbox_count;
    END IF;

    IF pending_event_count <> 3 THEN
        RAISE EXCEPTION 'expected pending event count 3, got %', pending_event_count;
    END IF;
END $$;

WITH counts AS (
    SELECT
        COUNT(*) FILTER (
            WHERE aggregate_id = -17001001
        ) AS captured_event_count,
        COUNT(*) FILTER (
            WHERE aggregate_id = -17001001
              AND event_type = 'PRODUCT_CREATED'
        ) AS create_event_count,
        COUNT(*) FILTER (
            WHERE aggregate_id = -17001001
              AND event_type = 'PRODUCT_UPDATED'
        ) AS update_event_count,
        COUNT(*) FILTER (
            WHERE aggregate_id = -17001001
              AND event_type = 'PRODUCT_STATUS_CHANGED'
        ) AS status_change_event_count,
        COUNT(*) FILTER (
            WHERE aggregate_id = -17001002
        ) AS rollback_outbox_count,
        COUNT(*) FILTER (
            WHERE aggregate_id = -17001001
              AND status = 'PENDING'
        ) AS pending_event_count
    FROM search_outbox
    WHERE aggregate_type = 'PRODUCT'
      AND aggregate_id IN (-17001001, -17001002)
),
products_summary AS (
    SELECT
        COUNT(*) FILTER (WHERE id = -17001001) AS committed_product_count,
        COALESCE(MAX(price) FILTER (WHERE id = -17001001), 0) AS committed_product_price,
        COALESCE(MAX(status) FILTER (WHERE id = -17001001), '') AS committed_product_status,
        COUNT(*) FILTER (WHERE id = -17001002) AS rollback_product_count
    FROM products
    WHERE id IN (-17001001, -17001002)
)
SELECT jsonb_build_object(
    'dbTarget', 'docker compose postgres/readpath_lab',
    'schemaStatus', 'applied',
    'transactionAtomicity', 'pass',
    'commitScenario', jsonb_build_object(
        'productId', -17001001,
        'productCount', products_summary.committed_product_count,
        'createEventCount', counts.create_event_count,
        'createEventStatus', 'PENDING'
    ),
    'updateScenario', jsonb_build_object(
        'productId', -17001001,
        'price', products_summary.committed_product_price,
        'updateEventCount', counts.update_event_count,
        'updateEventStatus', 'PENDING'
    ),
    'rollbackScenario', jsonb_build_object(
        'productId', -17001002,
        'productCount', products_summary.rollback_product_count,
        'outboxCount', counts.rollback_outbox_count
    ),
    'statusChangeScenario', jsonb_build_object(
        'productId', -17001001,
        'status', products_summary.committed_product_status,
        'statusChangeEventCount', counts.status_change_event_count,
        'statusChangeEventStatus', 'PENDING'
    ),
    'counts', jsonb_build_object(
        'capturedEventCount', counts.captured_event_count,
        'createEventCount', counts.create_event_count,
        'updateEventCount', counts.update_event_count,
        'statusChangeEventCount', counts.status_change_event_count,
        'rollbackOutboxCount', counts.rollback_outbox_count,
        'pendingEventCount', counts.pending_event_count
    ),
    'finalSmokeStatus', 'pass'
)::TEXT
FROM counts
CROSS JOIN products_summary;
