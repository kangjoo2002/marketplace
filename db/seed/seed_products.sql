\set ON_ERROR_STOP on
\timing on

-- Manual product seed for the read-path benchmark.
-- This script truncates only the selected profile table before inserting
-- exactly 10,000,000 rows into that table.
--
-- Supported psql variables:
--   -v seed_profile=uniform
--   -v seed_profile=moderate-skew
--   -v seed_profile=high-skew
--   -v chunk_size=500000
--
-- If seed_profile is omitted, moderate-skew is used.
-- If chunk_size is omitted, 500,000 rows per chunk is used.
-- The generation is deterministic arithmetic, not random(), so repeated runs
-- with the same profile produce the same distribution shape relative to run time.

\if :{?seed_profile}
\else
\set seed_profile 'moderate-skew'
\endif

\if :{?chunk_size}
\else
\set chunk_size 500000
\endif

SET jit = off;
SET synchronous_commit = off;

CREATE TEMP TABLE seed_products_config (
    profile TEXT NOT NULL,
    target_table TEXT NOT NULL,
    chunk_size BIGINT NOT NULL,
    target_count BIGINT NOT NULL
);

INSERT INTO seed_products_config (profile, target_table, chunk_size, target_count)
SELECT
    :'seed_profile',
    CASE :'seed_profile'
        WHEN 'uniform' THEN 'products_uniform'
        WHEN 'moderate-skew' THEN 'products_moderate_skew'
        WHEN 'high-skew' THEN 'products_high_skew'
        ELSE ''
    END,
    :'chunk_size',
    10000000;

DO $$
DECLARE
    selected_profile TEXT;
    selected_target_table TEXT;
    selected_chunk_size BIGINT;
    selected_target_count BIGINT;
    table_name TEXT;
BEGIN
    SELECT profile, target_table, chunk_size, target_count
    INTO selected_profile, selected_target_table, selected_chunk_size, selected_target_count
    FROM seed_products_config;

    IF selected_profile NOT IN ('uniform', 'moderate-skew', 'high-skew') THEN
        RAISE EXCEPTION
            'Unsupported seed_profile: %. Supported profiles: uniform, moderate-skew, high-skew',
            selected_profile;
    END IF;

    IF selected_target_table NOT IN ('products_uniform', 'products_moderate_skew', 'products_high_skew') THEN
        RAISE EXCEPTION 'Unsupported target table resolved from seed_profile: %', selected_target_table;
    END IF;

    IF selected_chunk_size <= 0 THEN
        RAISE EXCEPTION 'chunk_size must be a positive integer. Provided: %', selected_chunk_size;
    END IF;

    IF selected_target_count != 10000000 THEN
        RAISE EXCEPTION 'target_count must remain fixed at 10000000. Provided: %', selected_target_count;
    END IF;

    FOREACH table_name IN ARRAY ARRAY['products_uniform', 'products_moderate_skew', 'products_high_skew'] LOOP
        EXECUTE format($ddl$
            CREATE TABLE IF NOT EXISTS %I (
                id BIGSERIAL PRIMARY KEY,
                seller_id BIGINT NOT NULL,
                category_id BIGINT NOT NULL,
                brand_id BIGINT NOT NULL,
                status VARCHAR(20) NOT NULL,
                price INTEGER NOT NULL CHECK (price >= 0),
                rating NUMERIC(3,2) NOT NULL CHECK (rating >= 0 AND rating <= 5),
                review_count INTEGER NOT NULL CHECK (review_count >= 0),
                created_at TIMESTAMP NOT NULL,
                updated_at TIMESTAMP NOT NULL,
                CHECK (status IN ('ACTIVE', 'SOLD_OUT', 'DELETED'))
            )
        $ddl$, table_name);
    END LOOP;

    IF to_regclass('products_active') IS NULL THEN
        CREATE VIEW products_active AS
        SELECT * FROM products_moderate_skew;
    END IF;
END $$;

DO $$
DECLARE
    selected_profile TEXT;
    selected_target_table TEXT;
    selected_chunk_size BIGINT;
    selected_target_count BIGINT;
    next_id BIGINT := 1;
    end_id BIGINT;
    inserted_so_far BIGINT := 0;
    rows_inserted BIGINT;
    started_at TIMESTAMPTZ := clock_timestamp();
    chunk_started_at TIMESTAMPTZ;
BEGIN
    SELECT profile, target_table, chunk_size, target_count
    INTO selected_profile, selected_target_table, selected_chunk_size, selected_target_count
    FROM seed_products_config;

    EXECUTE format('TRUNCATE TABLE %I RESTART IDENTITY', selected_target_table);

    RAISE NOTICE
        'seeding products profile=% target_table=% target=% chunk_size=%',
        selected_profile,
        selected_target_table,
        selected_target_count,
        selected_chunk_size;

    WHILE next_id <= selected_target_count LOOP
        end_id := LEAST(next_id + selected_chunk_size - 1, selected_target_count);
        chunk_started_at := clock_timestamp();

        EXECUTE format($insert$
            INSERT INTO %I (
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
            WITH raw AS (
                SELECT
                    gs::BIGINT AS n,
                    $3::TEXT AS profile,
                    ((gs::BIGINT * 214013 + 2531011) %% 1000000)::INTEGER AS h_seller,
                    ((gs::BIGINT * 174763 + 192437) %% 1000000)::INTEGER AS h_category,
                    ((gs::BIGINT * 48271 + 128201) %% 1000000)::INTEGER AS h_brand,
                    ((gs::BIGINT * 69621 + 47237) %% 1000000)::INTEGER AS h_status,
                    ((gs::BIGINT * 93089 + 13579) %% 1000000)::INTEGER AS h_price,
                    ((gs::BIGINT * 199999 + 424243) %% 1000000)::INTEGER AS h_rating,
                    ((gs::BIGINT * 122949 + 77777) %% 1000000)::INTEGER AS h_review,
                    ((gs::BIGINT * 44497 + 246813) %% 1000000)::INTEGER AS h_created,
                    ((gs::BIGINT * 23209 + 97531) %% 1000000)::INTEGER AS h_updated
                FROM generate_series($1, $2) AS gs
            ),
            seller_assigned AS (
                SELECT
                    *,
                    CASE profile
                        WHEN 'uniform' THEN ((n - 1) %% 50000) + 1
                        WHEN 'moderate-skew' THEN
                            CASE
                                WHEN h_seller < 550000 THEN (h_seller %% 5000) + 1
                                ELSE 5001 + (h_seller %% 45000)
                            END
                        WHEN 'high-skew' THEN
                            CASE
                                WHEN h_seller < 700000 THEN (h_seller %% 2500) + 1
                                ELSE 2501 + (h_seller %% 47500)
                            END
                    END::BIGINT AS seller_id
                FROM raw
            ),
            seller_focus AS (
                SELECT
                    *,
                    CASE
                        WHEN profile = 'uniform' THEN ((seller_id - 1) %% 500) + 1
                        WHEN profile = 'moderate-skew' AND seller_id <= 5000 THEN ((seller_id - 1) %% 100) + 1
                        WHEN profile = 'moderate-skew' THEN 101 + ((seller_id - 5001) %% 400)
                        WHEN profile = 'high-skew' AND seller_id <= 2500 THEN ((seller_id - 1) %% 50) + 1
                        ELSE 51 + ((seller_id - 2501) %% 450)
                    END::BIGINT AS seller_focus_category
                FROM seller_assigned
            ),
            category_assigned AS (
                SELECT
                    *,
                    CASE profile
                        WHEN 'uniform' THEN
                            ((seller_focus_category - 1 + (((n - 1) / 50000) %% 3)) %% 500) + 1
                        WHEN 'moderate-skew' THEN
                            CASE
                                WHEN seller_id <= 5000 THEN
                                    CASE
                                        WHEN h_category < 700000 THEN ((seller_focus_category - 1 + (h_category %% 5)) %% 100) + 1
                                        ELSE 101 + (h_category %% 400)
                                    END
                                ELSE
                                    CASE
                                        WHEN h_category < 700000 THEN 101 + ((seller_focus_category - 101 + (h_category %% 5)) %% 400)
                                        ELSE 1 + (h_category %% 100)
                                    END
                            END
                        WHEN 'high-skew' THEN
                            CASE
                                WHEN seller_id <= 2500 THEN
                                    CASE
                                        WHEN h_category < 850000 THEN ((seller_focus_category - 1 + (h_category %% 3)) %% 50) + 1
                                        ELSE 51 + (h_category %% 450)
                                    END
                                ELSE
                                    CASE
                                        WHEN h_category < 750000 THEN 51 + ((seller_focus_category - 51 + (h_category %% 7)) %% 450)
                                        ELSE 1 + (h_category %% 50)
                                    END
                            END
                    END::BIGINT AS category_id
                FROM seller_focus
            ),
            brand_assigned AS (
                SELECT
                    *,
                    CASE profile
                        WHEN 'uniform' THEN
                            CASE
                                WHEN h_brand < 100000 THEN 1 + (h_brand %% 200)
                                ELSE 201 + ((((category_id - 1) * 10) + ((seller_id + ((n - 1) / 50000)) %% 10)) %% 4800)
                            END
                        WHEN 'moderate-skew' THEN
                            CASE
                                WHEN category_id <= 100 AND h_brand < 350000 THEN 1 + (h_brand %% 100)
                                WHEN h_brand < 450000 THEN 101 + (h_brand %% 100)
                                WHEN category_id <= 100 AND h_brand < 750000 THEN 201 + ((((category_id - 1) * 10) + (h_brand %% 4)) %% 4800)
                                WHEN category_id > 100 AND h_brand < 700000 THEN 201 + ((((category_id - 1) * 10) + (h_brand %% 6)) %% 4800)
                                ELSE 201 + ((((category_id - 1) * 10) + (h_brand %% 10)) %% 4800)
                            END
                        WHEN 'high-skew' THEN
                            CASE
                                WHEN category_id <= 50 AND h_brand < 550000 THEN 1 + (h_brand %% 50)
                                WHEN h_brand < 700000 THEN 51 + (h_brand %% 150)
                                WHEN category_id <= 50 AND h_brand < 920000 THEN 201 + ((((category_id - 1) * 10) + (h_brand %% 3)) %% 4800)
                                WHEN category_id > 50 AND h_brand < 800000 THEN 201 + ((((category_id - 1) * 10) + (h_brand %% 5)) %% 4800)
                                ELSE 201 + ((((category_id - 1) * 10) + (h_brand %% 10)) %% 4800)
                            END
                    END::BIGINT AS brand_id
                FROM category_assigned
            ),
            product_values AS (
                SELECT
                    n,
                    seller_id,
                    category_id,
                    brand_id,
                    CASE
                        WHEN profile = 'high-skew' THEN
                            CASE
                                WHEN h_status < 950000 THEN 'ACTIVE'
                                WHEN h_status < 990000 THEN 'SOLD_OUT'
                                ELSE 'DELETED'
                            END
                        ELSE
                            CASE
                                WHEN h_status < 900000 THEN 'ACTIVE'
                                WHEN h_status < 970000 THEN 'SOLD_OUT'
                                ELSE 'DELETED'
                            END
                    END AS status,
                    CASE
                        WHEN h_price < 700000 THEN 10000 + (h_price %% 90001)
                        WHEN h_price < 850000 THEN 1000 + (h_price %% 9000)
                        ELSE 100001 + (h_price %% 900000)
                    END::INTEGER AS price,
                    ((h_rating %% 501)::NUMERIC / 100)::NUMERIC(3, 2) AS rating,
                    CASE
                        WHEN h_review < 850000 THEN h_review %% 21
                        WHEN h_review < 970000 THEN 21 + (h_review %% 180)
                        WHEN h_review < 995000 THEN 201 + (h_review %% 800)
                        ELSE 1000 + (h_review %% 9000)
                    END::INTEGER AS review_count,
                    (
                        LOCALTIMESTAMP
                        - CASE
                            WHEN h_created < 300000 THEN (h_created %% 30) * INTERVAL '1 day'
                            ELSE (30 + (h_created %% 699)) * INTERVAL '1 day'
                          END
                        - (h_updated %% 86400) * INTERVAL '1 second'
                    )::TIMESTAMP AS created_at,
                    h_updated
                FROM brand_assigned
            )
            SELECT
                n AS id,
                seller_id,
                category_id,
                brand_id,
                status,
                price,
                rating,
                review_count,
                created_at,
                LEAST(
                    LOCALTIMESTAMP,
                    created_at
                        + (h_updated %% 60) * INTERVAL '1 day'
                        + ((h_updated / 60) %% 86400) * INTERVAL '1 second'
                )::TIMESTAMP AS updated_at
            FROM product_values
        $insert$, selected_target_table)
        USING next_id, end_id, selected_profile;

        GET DIAGNOSTICS rows_inserted = ROW_COUNT;
        inserted_so_far := inserted_so_far + rows_inserted;

        RAISE NOTICE
            'inserted % / % products (% percent) target_table=% range=%-% chunk_elapsed=% total_elapsed=%',
            inserted_so_far,
            selected_target_count,
            ROUND(inserted_so_far * 100.0 / selected_target_count, 1),
            selected_target_table,
            next_id,
            end_id,
            clock_timestamp() - chunk_started_at,
            clock_timestamp() - started_at;

        next_id := end_id + 1;
    END LOOP;

    EXECUTE 'SELECT setval(pg_get_serial_sequence($1, ''id''), $2, true)'
    USING selected_target_table, selected_target_count;

    EXECUTE format('ANALYZE %I', selected_target_table);

    RAISE NOTICE
        'seed complete profile=% target_table=% inserted=% target=% total_elapsed=%',
        selected_profile,
        selected_target_table,
        inserted_so_far,
        selected_target_count,
        clock_timestamp() - started_at;
END $$;

SELECT format('SELECT COUNT(*) AS seeded_product_count FROM %I', target_table)
FROM seed_products_config
\gexec
