package com.portfolio.marketplace.productsearch.infrastructure.opensearch;

import java.util.Map;

public interface OpenSearchHttpClient {

	Map<String, Object> search(Map<String, Object> query);
}



