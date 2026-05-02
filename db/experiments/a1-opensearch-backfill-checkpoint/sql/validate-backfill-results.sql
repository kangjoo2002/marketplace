\set ON_ERROR_STOP on

SELECT jsonb_build_object(
    'sourceProductCount', (
        SELECT COUNT(*)
        FROM products
        WHERE id BETWEEN -19002999 AND -19002000
    ),
    'firstProductId', (
        SELECT MIN(id)
        FROM products
        WHERE id BETWEEN -19002999 AND -19002000
    ),
    'lastProductId', (
        SELECT MAX(id)
        FROM products
        WHERE id BETWEEN -19002999 AND -19002000
    ),
    'productsWithOptions', (
        SELECT COUNT(DISTINCT p.id)
        FROM products p
        JOIN product_options_moderate_skew po ON po.product_id = p.id
        WHERE p.id BETWEEN -19002999 AND -19002000
    ),
    'productsWithoutOptions', (
        SELECT COUNT(*)
        FROM products p
        WHERE p.id BETWEEN -19002999 AND -19002000
          AND NOT EXISTS (
              SELECT 1
              FROM product_options_moderate_skew po
              WHERE po.product_id = p.id
          )
    )
)::TEXT;
