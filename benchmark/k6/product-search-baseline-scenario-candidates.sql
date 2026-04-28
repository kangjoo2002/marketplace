\set ON_ERROR_STOP on

-- Candidate discovery evidence for product-search-baseline-v1.
--
-- This script evaluates the B1/B2/B3 candidates and rejected fallbacks used to
-- select the proposed shared scenario constants. It intentionally does not run
-- EXPLAIN, create indexes, change data, or exercise tuned/API-alternative read
-- paths.

WITH candidate_sets AS (
    SELECT *
    FROM (
        VALUES
            ('B1_selective_option_filter', 1, 'recommended: category+brand+price+option', 'ACTIVE', 40::BIGINT, 592::BIGINT, 10000::INT, 100000::INT, 'RED', 'M', 'IN_STOCK', 'reviewCountDesc', 50, 100, 1, 'Most selective passing category+brand+price+option candidate found across all profiles.'),
            ('B1_selective_option_filter', 2, 'passing alternative: category+brand+price+option', 'ACTIVE', 41::BIGINT, 603::BIGINT, 10000::INT, 100000::INT, 'GRAY', 'FREE', 'IN_STOCK', 'reviewCountDesc', 50, 100, 1, 'Top-5 passing B1 candidate retained as evidence.'),
            ('B1_selective_option_filter', 3, 'passing alternative: category+brand+price+option', 'ACTIVE', 23::BIGINT, 423::BIGINT, 10000::INT, 100000::INT, 'GRAY', 'L', 'IN_STOCK', 'reviewCountDesc', 50, 100, 1, 'Top-5 passing B1 candidate retained as evidence.'),
            ('B1_selective_option_filter', 4, 'passing alternative: category+brand+price+option', 'ACTIVE', 41::BIGINT, 601::BIGINT, 10000::INT, 100000::INT, 'GRAY', 'FREE', 'IN_STOCK', 'reviewCountDesc', 50, 100, 1, 'Top-5 passing B1 candidate retained as evidence.'),
            ('B1_selective_option_filter', 5, 'passing alternative: category+brand+price+option', 'ACTIVE', 13::BIGINT, 321::BIGINT, 10000::INT, 100000::INT, 'BLACK', 'XL', 'IN_STOCK', 'reviewCountDesc', 50, 100, 1, 'Top-5 passing B1 candidate retained as evidence.'),
            ('B1_selective_option_filter', 90, 'rejected old OUT_OF_STOCK candidate', 'ACTIVE', 35::BIGINT, 543::BIGINT, 10000::INT, 100000::INT, 'WHITE', 'L', 'OUT_OF_STOCK', 'reviewCountDesc', 50, 100, 1, 'Rejected because it is zero-result for some profiles and OUT_OF_STOCK-only.'),
            ('B1_selective_option_filter', 91, 'rejected 35/543 with shared IN_STOCK option', 'ACTIVE', 35::BIGINT, 543::BIGINT, 10000::INT, 100000::INT, 'BLACK', 'M', 'IN_STOCK', 'reviewCountDesc', 50, 100, 1, 'Rejected because categoryId=35 and brandId=543 are candidates only and do not pass with shared IN_STOCK option constants.'),
            ('B2_broad_active_option_filter', 1, 'recommended: broad active option listing', 'ACTIVE', NULL::BIGINT, NULL::BIGINT, NULL::INT, NULL::INT, 'RED', 'M', 'IN_STOCK', 'createdAtDesc', 50, 100, 0, 'Broad scenario intentionally omits categoryId and brandId.'),
            ('B3_deep_offset_option_filter', 1, 'recommended: category+price+option offset 1000', 'ACTIVE', 40::BIGINT, NULL::BIGINT, 10000::INT, 100000::INT, 'RED', 'M', 'IN_STOCK', 'createdAtDesc', 50, 1000, 4, 'Selected after category+brand candidates failed offset 500; offset 1000 is the largest passing offset for this category-only candidate.'),
            ('B3_deep_offset_option_filter', 80, 'rejected same as B1 with price at offset 500', 'ACTIVE', 40::BIGINT, 592::BIGINT, 10000::INT, 100000::INT, 'RED', 'M', 'IN_STOCK', 'createdAtDesc', 50, 500, 1, 'Rejected because the B1 category+brand+price candidate does not reach required_min_count 550.'),
            ('B3_deep_offset_option_filter', 81, 'rejected same as B1 with price relaxed at offset 500', 'ACTIVE', 40::BIGINT, 592::BIGINT, NULL::INT, NULL::INT, 'RED', 'M', 'IN_STOCK', 'createdAtDesc', 50, 500, 2, 'Rejected because relaxing price still does not reach required_min_count 550.'),
            ('B3_deep_offset_option_filter', 82, 'rejected nearest category+brand no-price candidate at offset 500', 'ACTIVE', 13::BIGINT, 321::BIGINT, NULL::INT, NULL::INT, 'BLACK', 'XL', 'IN_STOCK', 'createdAtDesc', 50, 500, 3, 'Nearest category+brand candidate found; rejected because minimum profile count remains below 550.'),
            ('B3_deep_offset_option_filter', 83, 'rejected recommended category-only candidate at offset 5000', 'ACTIVE', 40::BIGINT, NULL::BIGINT, 10000::INT, 100000::INT, 'RED', 'M', 'IN_STOCK', 'createdAtDesc', 50, 5000, 4, 'Rejected because category-only candidate passes offset 1000 but not offset 5000.')
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
    SELECT 'uniform' AS profile, s.*, m.matching_count
    FROM candidate_sets s
    CROSS JOIN LATERAL (
        SELECT COUNT(DISTINCT p.id) AS matching_count
        FROM products_uniform p
        JOIN product_options_uniform po ON po.product_id = p.id
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
    SELECT 'moderate_skew' AS profile, s.*, m.matching_count
    FROM candidate_sets s
    CROSS JOIN LATERAL (
        SELECT COUNT(DISTINCT p.id) AS matching_count
        FROM products_moderate_skew p
        JOIN product_options_moderate_skew po ON po.product_id = p.id
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
    SELECT 'high_skew' AS profile, s.*, m.matching_count
    FROM candidate_sets s
    CROSS JOIN LATERAL (
        SELECT COUNT(DISTINCT p.id) AS matching_count
        FROM products_high_skew p
        JOIN product_options_high_skew po ON po.product_id = p.id
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
