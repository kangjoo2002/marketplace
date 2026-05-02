package com.portfolio.readpath_lab.product.application;

import org.springframework.boot.context.properties.ConfigurationProperties;

@ConfigurationProperties(prefix = "readpath.product-search")
public class ProductSearchReadPathProperties {

	private String readPath = "db";
	private OpenSearch openSearch = new OpenSearch();

	public String getReadPath() {
		return readPath;
	}

	public void setReadPath(String readPath) {
		this.readPath = readPath;
	}

	public OpenSearch getOpenSearch() {
		return openSearch;
	}

	public void setOpenSearch(OpenSearch openSearch) {
		this.openSearch = openSearch;
	}

	public boolean isOpenSearchReadPath() {
		return "opensearch".equalsIgnoreCase(readPath);
	}

	public String normalizedReadPath() {
		if ("db".equalsIgnoreCase(readPath)) {
			return "db";
		}
		if ("opensearch".equalsIgnoreCase(readPath)) {
			return "opensearch";
		}
		throw new IllegalArgumentException("Unsupported product search read path: " + readPath);
	}

	public static class OpenSearch {

		private String baseUrl = "http://localhost:9200";
		private String indexAlias = "products_search_read";
		private int timeoutMs = 500;

		public String getBaseUrl() {
			return baseUrl;
		}

		public void setBaseUrl(String baseUrl) {
			this.baseUrl = baseUrl;
		}

		public String getIndexAlias() {
			return indexAlias;
		}

		public void setIndexAlias(String indexAlias) {
			this.indexAlias = indexAlias;
		}

		public int getTimeoutMs() {
			return timeoutMs;
		}

		public void setTimeoutMs(int timeoutMs) {
			this.timeoutMs = timeoutMs;
		}
	}
}
