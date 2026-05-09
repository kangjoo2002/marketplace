package com.portfolio.marketplace.productsearch.infrastructure.opensearch;

import java.util.Map;

public interface OpenSearchDocumentClient {

	void indexDocument(String documentId, Map<String, Object> document);

	void deleteDocument(String documentId);
}
