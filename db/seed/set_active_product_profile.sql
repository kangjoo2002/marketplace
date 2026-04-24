\set ON_ERROR_STOP on
\timing on

\if :{?active_profile}
\else
\set active_profile 'moderate-skew'
\endif

CREATE TEMP TABLE set_active_product_profile_config (
    active_profile TEXT NOT NULL,
    target_table TEXT NOT NULL
);

INSERT INTO set_active_product_profile_config (active_profile, target_table)
SELECT
    :'active_profile',
    CASE :'active_profile'
        WHEN 'uniform' THEN 'products_uniform'
        WHEN 'moderate-skew' THEN 'products_moderate_skew'
        WHEN 'high-skew' THEN 'products_high_skew'
        ELSE ''
    END;

DO $$
DECLARE
    selected_active_profile TEXT;
    selected_target_table TEXT;
BEGIN
    SELECT active_profile, target_table
    INTO selected_active_profile, selected_target_table
    FROM set_active_product_profile_config;

    IF selected_active_profile NOT IN ('uniform', 'moderate-skew', 'high-skew') THEN
        RAISE EXCEPTION
            'Unsupported active_profile: %. Supported profiles: uniform, moderate-skew, high-skew',
            selected_active_profile;
    END IF;

    IF to_regclass(selected_target_table) IS NULL THEN
        RAISE EXCEPTION
            'Target profile table does not exist: %. Run seed_products.sql for active_profile=% first.',
            selected_target_table,
            selected_active_profile;
    END IF;

    EXECUTE format(
        'CREATE OR REPLACE VIEW products_active AS SELECT * FROM %I',
        selected_target_table
    );

    RAISE NOTICE
        'products_active now points to % for active_profile=%',
        selected_target_table,
        selected_active_profile;
END $$;
