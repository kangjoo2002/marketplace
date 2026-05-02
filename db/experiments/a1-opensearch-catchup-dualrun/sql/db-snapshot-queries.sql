\set ON_ERROR_STOP on

-- Representative exact-filter DB snapshot queries used by the catch-up dual-run smoke.
-- The PowerShell smoke script executes equivalent SQL inline so that it can capture
-- top-k IDs and compare them with OpenSearch results in a single artifact set.

-- C1: selective option filter with same-option-row semantics.
SELECT p.id
FROM products p
WHERE p.id BETWEEN -20002999 AND -20002000
  AND p.status = 'ACTIVE'
  AND p.category_id = 75
  AND p.brand_id = 943
  AND EXISTS (
      SELECT 1
      FROM product_options_moderate_skew po
      WHERE po.product_id = p.id
        AND po.color = 'BLACK'
        AND po.size = 'S'
        AND po.stock_status = 'IN_STOCK'
  )
ORDER BY p.review_count DESC, p.id DESC
LIMIT 50;

-- C2: broad active/status filter with deterministic ordering.
SELECT p.id
FROM products p
WHERE p.id BETWEEN -20002999 AND -20002000
  AND p.status = 'ACTIVE'
ORDER BY p.review_count DESC, p.id DESC
LIMIT 50;

-- C3: deleted/status-changed product exclusion check.
SELECT p.id
FROM products p
WHERE p.id BETWEEN -20002999 AND -20002000
  AND p.status = 'ACTIVE'
  AND EXISTS (
      SELECT 1
      FROM product_options_moderate_skew po
      WHERE po.product_id = p.id
        AND po.color = 'GRAY'
        AND po.size = 'M'
        AND po.stock_status = 'LOW_STOCK'
  )
ORDER BY p.review_count DESC, p.id DESC
LIMIT 50;
