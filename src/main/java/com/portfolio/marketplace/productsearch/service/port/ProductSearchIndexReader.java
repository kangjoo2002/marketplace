package com.portfolio.marketplace.productsearch.service.port;

import com.portfolio.marketplace.productsearch.domain.ProductSearchCondition;
import com.portfolio.marketplace.productsearch.domain.ProductSearchItem;
import java.util.List;

public interface ProductSearchIndexReader {

	List<ProductSearchItem> search(ProductSearchCondition condition);
}
