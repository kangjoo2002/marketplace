package com.portfolio.marketplace.productsearch.infrastructure.opensearch;

import java.util.Map;

public interface OpenSearchSearchClient {

	Map<String, Object> search(Map<String, Object> query);
}
