\set ON_ERROR_STOP on
\timing on

-- Product options schema for local synthetic JOIN bottleneck experiments.
--
-- This script creates one product_options table for each products profile:
--   products_uniform        -> product_options_uniform
--   products_moderate_skew  -> product_options_moderate_skew
--   products_high_skew      -> product_options_high_skew
--
-- Foreign keys and product_options query tuning indexes are intentionally
-- omitted for local seed speed and to keep later JOIN/index experiments clean.

DO $$
DECLARE
    table_name TEXT;
BEGIN
    FOREACH table_name IN ARRAY ARRAY[
        'product_options_uniform',
        'product_options_moderate_skew',
        'product_options_high_skew'
    ] LOOP
        EXECUTE format($ddl$
            CREATE TABLE IF NOT EXISTS %I (
                id BIGINT PRIMARY KEY,
                product_id BIGINT NOT NULL,
                color VARCHAR(20) NOT NULL,
                size VARCHAR(10) NOT NULL,
                stock_status VARCHAR(20) NOT NULL,
                CHECK (color IN ('BLACK', 'WHITE', 'RED', 'BLUE', 'GREEN', 'GRAY', 'NAVY', 'BEIGE')),
                CHECK (size IN ('XS', 'S', 'M', 'L', 'XL', 'FREE')),
                CHECK (stock_status IN ('IN_STOCK', 'LOW_STOCK', 'OUT_OF_STOCK'))
            )
        $ddl$, table_name);
    END LOOP;
END $$;

SELECT
    schemaname,
    tablename
FROM pg_tables
WHERE schemaname = 'public'
  AND tablename IN (
      'product_options_uniform',
      'product_options_moderate_skew',
      'product_options_high_skew'
  )
ORDER BY tablename;
