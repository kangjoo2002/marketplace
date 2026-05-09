package com.portfolio.marketplace.productsearch.service.port;

import com.portfolio.marketplace.productsearch.domain.ProductSearchDocument;

public interface ProductSearchIndexWriter {

	void upsert(ProductSearchDocument document);

	void deleteByProductId(long productId);
}
