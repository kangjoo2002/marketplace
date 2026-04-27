\set ON_ERROR_STOP on
\timing on

-- Deterministic product_options seed for the read-path benchmark.
--
-- Supported psql variables:
--   -v seed_profile=uniform
--   -v seed_profile=moderate-skew
--   -v seed_profile=high-skew
--   -v chunk_size=500000
--
-- If seed_profile is omitted, moderate-skew is used.
-- If chunk_size is omitted, 500,000 products per chunk is used.
-- The generation is deterministic arithmetic, not random().

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

CREATE TEMP TABLE seed_product_options_config (
    profile TEXT NOT NULL,
    products_table TEXT NOT NULL,
    options_table TEXT NOT NULL,
    chunk_size BIGINT NOT NULL,
    target_product_count BIGINT NOT NULL
);

INSERT INTO seed_product_options_config (
    profile,
    products_table,
    options_table,
    chunk_size,
    target_product_count
)
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
    END,
    :'chunk_size',
    10000000;

DO $$
DECLARE
    selected_profile TEXT;
    selected_products_table TEXT;
    selected_options_table TEXT;
    selected_chunk_size BIGINT;
    selected_target_product_count BIGINT;
    actual_product_count BIGINT;
BEGIN
    SELECT profile, products_table, options_table, chunk_size, target_product_count
    INTO selected_profile, selected_products_table, selected_options_table, selected_chunk_size, selected_target_product_count
    FROM seed_product_options_config;

    IF selected_profile NOT IN ('uniform', 'moderate-skew', 'high-skew') THEN
        RAISE EXCEPTION
            'Unsupported seed_profile: %. Supported profiles: uniform, moderate-skew, high-skew',
            selected_profile;
    END IF;

    IF selected_chunk_size <= 0 THEN
        RAISE EXCEPTION 'chunk_size must be a positive integer. Provided: %', selected_chunk_size;
    END IF;

    IF to_regclass(selected_products_table) IS NULL THEN
        RAISE EXCEPTION 'products table does not exist: %', selected_products_table;
    END IF;

    IF to_regclass(selected_options_table) IS NULL THEN
        RAISE EXCEPTION 'product_options table does not exist: %. Run product_options_schema.sql first.', selected_options_table;
    END IF;

    EXECUTE format('SELECT COUNT(*) FROM %I', selected_products_table)
    INTO actual_product_count;

    IF actual_product_count != selected_target_product_count THEN
        RAISE EXCEPTION
            'Expected % products in %, but found %. Seed/verify the matching products profile first.',
            selected_target_product_count,
            selected_products_table,
            actual_product_count;
    END IF;
END $$;

DO $$
DECLARE
    selected_profile TEXT;
    selected_products_table TEXT;
    selected_options_table TEXT;
    selected_chunk_size BIGINT;
    selected_target_product_count BIGINT;
    next_product_id BIGINT := 1;
    end_product_id BIGINT;
    rows_inserted BIGINT;
    inserted_so_far BIGINT := 0;
    started_at TIMESTAMPTZ := clock_timestamp();
    chunk_started_at TIMESTAMPTZ;
BEGIN
    SELECT profile, products_table, options_table, chunk_size, target_product_count
    INTO selected_profile, selected_products_table, selected_options_table, selected_chunk_size, selected_target_product_count
    FROM seed_product_options_config;

    EXECUTE format('TRUNCATE TABLE %I', selected_options_table);

    RAISE NOTICE
        'seeding product_options profile=% products_table=% options_table=% target_products=% chunk_size=%',
        selected_profile,
        selected_products_table,
        selected_options_table,
        selected_target_product_count,
        selected_chunk_size;

    WHILE next_product_id <= selected_target_product_count LOOP
        end_product_id := LEAST(next_product_id + selected_chunk_size - 1, selected_target_product_count);
        chunk_started_at := clock_timestamp();

        EXECUTE format($insert$
            INSERT INTO %I (
                id,
                product_id,
                color,
                size,
                stock_status
            )
            WITH product_seed AS (
                SELECT
                    p.id::BIGINT AS product_id,
                    $3::TEXT AS profile,
                    ((p.id::BIGINT * 1103515245 + 12345) %% 100)::INTEGER AS h_fanout
                FROM %I p
                WHERE p.id BETWEEN $1 AND $2
            ),
            fanout AS (
                SELECT
                    product_id,
                    profile,
                    CASE profile
                        WHEN 'uniform' THEN ((product_id - 1) %% 3) + 1
                        WHEN 'moderate-skew' THEN
                            CASE
                                WHEN h_fanout < 35 THEN 1
                                WHEN h_fanout < 70 THEN 2
                                WHEN h_fanout < 90 THEN 3
                                ELSE 4
                            END
                        WHEN 'high-skew' THEN
                            CASE
                                WHEN h_fanout < 65 THEN 1
                                WHEN h_fanout < 80 THEN 2
                                WHEN h_fanout < 95 THEN 4
                                ELSE 8
                            END
                    END::INTEGER AS options_per_product
                FROM product_seed
            ),
            option_rows AS (
                SELECT
                    product_id,
                    profile,
                    option_no,
                    ((product_id * 48271 + option_no * 128201) %% 100)::INTEGER AS h_color,
                    ((product_id * 69621 + option_no * 47237) %% 100)::INTEGER AS h_size,
                    ((product_id * 93089 + option_no * 13579) %% 100)::INTEGER AS h_stock
                FROM fanout
                CROSS JOIN LATERAL generate_series(1, options_per_product) AS option_no
            )
            SELECT
                product_id * 10 + option_no AS id,
                product_id,
                CASE profile
                    WHEN 'uniform' THEN
                        (ARRAY['BLACK', 'WHITE', 'RED', 'BLUE', 'GREEN', 'GRAY', 'NAVY', 'BEIGE'])[1 + (h_color %% 8)]
                    WHEN 'moderate-skew' THEN
                        CASE
                            WHEN h_color < 25 THEN 'BLACK'
                            WHEN h_color < 45 THEN 'WHITE'
                            WHEN h_color < 60 THEN 'GRAY'
                            WHEN h_color < 70 THEN 'BLUE'
                            WHEN h_color < 80 THEN 'RED'
                            WHEN h_color < 88 THEN 'GREEN'
                            WHEN h_color < 95 THEN 'NAVY'
                            ELSE 'BEIGE'
                        END
                    WHEN 'high-skew' THEN
                        CASE
                            WHEN h_color < 55 THEN 'BLACK'
                            WHEN h_color < 70 THEN 'WHITE'
                            WHEN h_color < 80 THEN 'GRAY'
                            WHEN h_color < 87 THEN 'NAVY'
                            WHEN h_color < 92 THEN 'BLUE'
                            WHEN h_color < 96 THEN 'RED'
                            WHEN h_color < 99 THEN 'GREEN'
                            ELSE 'BEIGE'
                        END
                END AS color,
                CASE profile
                    WHEN 'uniform' THEN
                        (ARRAY['XS', 'S', 'M', 'L', 'XL', 'FREE'])[1 + (h_size %% 6)]
                    WHEN 'moderate-skew' THEN
                        CASE
                            WHEN h_size < 25 THEN 'M'
                            WHEN h_size < 45 THEN 'L'
                            WHEN h_size < 62 THEN 'FREE'
                            WHEN h_size < 76 THEN 'S'
                            WHEN h_size < 89 THEN 'XL'
                            ELSE 'XS'
                        END
                    WHEN 'high-skew' THEN
                        CASE
                            WHEN h_size < 45 THEN 'M'
                            WHEN h_size < 70 THEN 'FREE'
                            WHEN h_size < 82 THEN 'L'
                            WHEN h_size < 90 THEN 'S'
                            WHEN h_size < 96 THEN 'XL'
                            ELSE 'XS'
                        END
                END AS size,
                CASE profile
                    WHEN 'uniform' THEN
                        CASE
                            WHEN h_stock < 40 THEN 'IN_STOCK'
                            WHEN h_stock < 70 THEN 'LOW_STOCK'
                            ELSE 'OUT_OF_STOCK'
                        END
                    WHEN 'moderate-skew' THEN
                        CASE
                            WHEN h_stock < 70 THEN 'IN_STOCK'
                            WHEN h_stock < 88 THEN 'LOW_STOCK'
                            ELSE 'OUT_OF_STOCK'
                        END
                    WHEN 'high-skew' THEN
                        CASE
                            WHEN h_stock < 88 THEN 'IN_STOCK'
                            WHEN h_stock < 97 THEN 'LOW_STOCK'
                            ELSE 'OUT_OF_STOCK'
                        END
                END AS stock_status
            FROM option_rows
        $insert$, selected_options_table, selected_products_table)
        USING next_product_id, end_product_id, selected_profile;

        GET DIAGNOSTICS rows_inserted = ROW_COUNT;
        inserted_so_far := inserted_so_far + rows_inserted;

        RAISE NOTICE
            'inserted % product_options for profile=% range=%-% rows_in_chunk=% chunk_elapsed=% total_elapsed=%',
            inserted_so_far,
            selected_profile,
            next_product_id,
            end_product_id,
            rows_inserted,
            clock_timestamp() - chunk_started_at,
            clock_timestamp() - started_at;

        next_product_id := end_product_id + 1;
    END LOOP;

    EXECUTE format('ANALYZE %I', selected_options_table);

    RAISE NOTICE
        'seed complete profile=% options_table=% inserted=% total_elapsed=%',
        selected_profile,
        selected_options_table,
        inserted_so_far,
        clock_timestamp() - started_at;
END $$;

SELECT format('SELECT %L AS options_table, COUNT(*) AS seeded_product_option_count FROM %I', options_table, options_table)
FROM seed_product_options_config
\gexec
