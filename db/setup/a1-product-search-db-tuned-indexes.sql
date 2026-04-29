\set ON_ERROR_STOP on
\timing on
\pset pager off

-- A-1 DB tuned path selected supporting indexes for the representative
-- moderate_skew benchmark.
--
-- Scope:
--   products_moderate_skew
--   product_options_moderate_skew
--
-- These are local benchmark supporting indexes, not production-proven indexes.
-- uniform/high_skew profile tables are intentionally not indexed by this setup.

CREATE INDEX IF NOT EXISTS idx_products_moderate_skew_active_cat_brand_review
ON products_moderate_skew(category_id, brand_id, review_count DESC, id DESC)
WHERE status = 'ACTIVE';

CREATE INDEX IF NOT EXISTS idx_products_moderate_skew_active_created
ON products_moderate_skew(created_at DESC, id DESC)
WHERE status = 'ACTIVE';

CREATE INDEX IF NOT EXISTS idx_product_options_moderate_skew_color_size_stock_product
ON product_options_moderate_skew(color, size, stock_status, product_id);

ANALYZE products_moderate_skew;
ANALYZE product_options_moderate_skew;

SELECT
    schemaname,
    tablename,
    indexname,
    indexdef
FROM pg_indexes
WHERE schemaname = 'public'
  AND indexname IN (
      'idx_products_moderate_skew_active_cat_brand_review',
      'idx_products_moderate_skew_active_created',
      'idx_product_options_moderate_skew_color_size_stock_product'
  )
ORDER BY tablename, indexname;
