package com.portfolio.marketplace.productsearch.config;

import com.portfolio.marketplace.global.error.BusinessException;
import com.portfolio.marketplace.productsearch.error.ProductSearchErrorCode;
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
		throw new BusinessException(ProductSearchErrorCode.UNSUPPORTED_READ_PATH);
	}

	public static class OpenSearch {

		private String baseUrl = "http://localhost:9200";
		private String indexAlias = "products_search_read";
		private String writeAlias = "products_search_write";
		private int timeoutMs = 500;
		private CircuitBreaker circuitBreaker = new CircuitBreaker();

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

		public String getWriteAlias() {
			return writeAlias;
		}

		public void setWriteAlias(String writeAlias) {
			this.writeAlias = writeAlias;
		}

		public int getTimeoutMs() {
			return timeoutMs;
		}

		public void setTimeoutMs(int timeoutMs) {
			this.timeoutMs = timeoutMs;
		}

		public CircuitBreaker getCircuitBreaker() {
			return circuitBreaker;
		}

		public void setCircuitBreaker(CircuitBreaker circuitBreaker) {
			this.circuitBreaker = circuitBreaker;
		}
	}

	public static class CircuitBreaker {

		private boolean enabled = true;
		private int failureThreshold = 3;
		private long openWaitMs = 1000;
		private int halfOpenPermittedCalls = 1;

		public boolean isEnabled() {
			return enabled;
		}

		public void setEnabled(boolean enabled) {
			this.enabled = enabled;
		}

		public int getFailureThreshold() {
			return failureThreshold;
		}

		public void setFailureThreshold(int failureThreshold) {
			this.failureThreshold = failureThreshold;
		}

		public long getOpenWaitMs() {
			return openWaitMs;
		}

		public void setOpenWaitMs(long openWaitMs) {
			this.openWaitMs = openWaitMs;
		}

		public int getHalfOpenPermittedCalls() {
			return halfOpenPermittedCalls;
		}

		public void setHalfOpenPermittedCalls(int halfOpenPermittedCalls) {
			this.halfOpenPermittedCalls = halfOpenPermittedCalls;
		}
	}
}



