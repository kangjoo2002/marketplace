\set ON_ERROR_STOP on

-- Final validation for the proposed product-search-baseline-v1 k6 constants.
--
-- This script validates only the recommended B1/B2/B3 constants against all
-- three matched synthetic profile table pairs. It intentionally does not run
-- EXPLAIN, create indexes, change data, or exercise tuned/API-alternative read
-- paths.

WITH candidate_sets AS (
    SELECT *
    FROM (
        VALUES
            (
                'B1_selective_option_filter',
                1,
                'recommended B1: selective category+brand+price+option search',
                'ACTIVE',
                40::BIGINT,
                592::BIGINT,
                10000::INT,
                100000::INT,
                'RED',
                'M',
                'IN_STOCK',
                'reviewCountDesc',
                50,
                100,
                1,
                'Strongest B1 shape found: categoryId+brandId+price range+option filters pass all profiles at offset 100.'
            ),
            (
                'B2_broad_active_option_filter',
                1,
                'recommended B2: broad active option-filtered listing',
                'ACTIVE',
                NULL::BIGINT,
                NULL::BIGINT,
                NULL::INT,
                NULL::INT,
                'RED',
                'M',
                'IN_STOCK',
                'createdAtDesc',
                50,
                100,
                0,
                'B2 is intentionally broad, so categoryId and brandId are omitted while option filters remain fixed.'
            ),
            (
                'B3_deep_offset_option_filter',
                1,
                'recommended B3: category+price+option deep OFFSET search',
                'ACTIVE',
                40::BIGINT,
                NULL::BIGINT,
                10000::INT,
                100000::INT,
                'RED',
                'M',
                'IN_STOCK',
                'createdAtDesc',
                50,
                1000,
                4,
                'categoryId+brandId candidates failed offset 500; category-only passes at offset 1000 and fails at 5000.'
            )
    ) AS s (
        scenario,
        candidate_rank,
        candidate_description,
        status,
        category_id,
        brand_id,
        min_price,
        max_price,
        color,
        size,
        stock_status,
        sort,
        limit_rows,
        offset_rows,
        fallback_level,
        selection_reason
    )
),
profile_validation AS (
    SELECT
        'uniform' AS profile,
        s.*,
        m.matching_count
    FROM candidate_sets s
    CROSS JOIN LATERAL (
        SELECT COUNT(DISTINCT p.id) AS matching_count
        FROM products_uniform p
        JOIN product_options_uniform po
          ON po.product_id = p.id
        WHERE p.status = s.status
          AND (s.category_id IS NULL OR p.category_id = s.category_id)
          AND (s.brand_id IS NULL OR p.brand_id = s.brand_id)
          AND (s.min_price IS NULL OR p.price >= s.min_price)
          AND (s.max_price IS NULL OR p.price <= s.max_price)
          AND po.color = s.color
          AND po.size = s.size
          AND po.stock_status = s.stock_status
    ) m
    UNION ALL
    SELECT
        'moderate_skew' AS profile,
        s.*,
        m.matching_count
    FROM candidate_sets s
    CROSS JOIN LATERAL (
        SELECT COUNT(DISTINCT p.id) AS matching_count
        FROM products_moderate_skew p
        JOIN product_options_moderate_skew po
          ON po.product_id = p.id
        WHERE p.status = s.status
          AND (s.category_id IS NULL OR p.category_id = s.category_id)
          AND (s.brand_id IS NULL OR p.brand_id = s.brand_id)
          AND (s.min_price IS NULL OR p.price >= s.min_price)
          AND (s.max_price IS NULL OR p.price <= s.max_price)
          AND po.color = s.color
          AND po.size = s.size
          AND po.stock_status = s.stock_status
    ) m
    UNION ALL
    SELECT
        'high_skew' AS profile,
        s.*,
        m.matching_count
    FROM candidate_sets s
    CROSS JOIN LATERAL (
        SELECT COUNT(DISTINCT p.id) AS matching_count
        FROM products_high_skew p
        JOIN product_options_high_skew po
          ON po.product_id = p.id
        WHERE p.status = s.status
          AND (s.category_id IS NULL OR p.category_id = s.category_id)
          AND (s.brand_id IS NULL OR p.brand_id = s.brand_id)
          AND (s.min_price IS NULL OR p.price >= s.min_price)
          AND (s.max_price IS NULL OR p.price <= s.max_price)
          AND po.color = s.color
          AND po.size = s.size
          AND po.stock_status = s.stock_status
    ) m
)
SELECT
    profile,
    scenario,
    candidate_rank,
    candidate_description,
    status,
    category_id,
    brand_id,
    min_price,
    max_price,
    color,
    size,
    stock_status,
    sort,
    limit_rows AS limit,
    offset_rows AS offset,
    matching_count,
    offset_rows + limit_rows AS required_min_count,
    matching_count >= offset_rows + limit_rows AS passes,
    fallback_level,
    selection_reason
FROM profile_validation
ORDER BY scenario, candidate_rank, profile;
