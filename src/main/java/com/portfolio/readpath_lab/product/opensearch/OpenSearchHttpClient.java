package com.portfolio.readpath_lab.product.opensearch;

import java.util.Map;

public interface OpenSearchHttpClient {

	Map<String, Object> search(Map<String, Object> query);
}
