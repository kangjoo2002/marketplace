CREATE TABLE IF NOT EXISTS product_options (
    id BIGSERIAL PRIMARY KEY,
    product_id BIGINT NOT NULL REFERENCES products(id),
    color VARCHAR(20) NOT NULL,
    size VARCHAR(10) NOT NULL,
    stock_status VARCHAR(20) NOT NULL,
    CHECK (color IN ('BLACK', 'WHITE', 'RED', 'BLUE', 'GREEN', 'GRAY', 'NAVY', 'BEIGE')),
    CHECK (size IN ('XS', 'S', 'M', 'L', 'XL', 'FREE')),
    CHECK (stock_status IN ('IN_STOCK', 'LOW_STOCK', 'OUT_OF_STOCK'))
);

CREATE INDEX IF NOT EXISTS idx_product_options_product_id
ON product_options(product_id);

CREATE INDEX IF NOT EXISTS idx_product_options_color_size_stock_product
ON product_options(color, size, stock_status, product_id);
