package com.portfolio.marketplace.productsearch.config;

import org.springframework.boot.context.properties.ConfigurationProperties;

@ConfigurationProperties(prefix = "readpath.product-search.indexing")
public class ProductSearchIndexingProperties {

	private Relay relay = new Relay();

	public Relay getRelay() {
		return relay;
	}

	public void setRelay(Relay relay) {
		this.relay = relay;
	}

	public static class Relay {

		private boolean enabled = false;
		private int batchSize = 20;
		private long fixedDelayMs = 5000;
		private int maxDrainRounds = 1;
		private int maxRetryCount = 3;
		private long retryDelayMs = 10000;
		private long processingTimeoutMs = 60000;
		private String instanceId = "local-relay";

		public boolean isEnabled() {
			return enabled;
		}

		public void setEnabled(boolean enabled) {
			this.enabled = enabled;
		}

		public int getBatchSize() {
			return batchSize;
		}

		public void setBatchSize(int batchSize) {
			this.batchSize = batchSize;
		}

		public long getFixedDelayMs() {
			return fixedDelayMs;
		}

		public void setFixedDelayMs(long fixedDelayMs) {
			this.fixedDelayMs = fixedDelayMs;
		}

		public int getMaxDrainRounds() {
			return maxDrainRounds;
		}

		public void setMaxDrainRounds(int maxDrainRounds) {
			this.maxDrainRounds = maxDrainRounds;
		}

		public int getMaxRetryCount() {
			return maxRetryCount;
		}

		public void setMaxRetryCount(int maxRetryCount) {
			this.maxRetryCount = maxRetryCount;
		}

		public long getRetryDelayMs() {
			return retryDelayMs;
		}

		public void setRetryDelayMs(long retryDelayMs) {
			this.retryDelayMs = retryDelayMs;
		}

		public long getProcessingTimeoutMs() {
			return processingTimeoutMs;
		}

		public void setProcessingTimeoutMs(long processingTimeoutMs) {
			this.processingTimeoutMs = processingTimeoutMs;
		}

		public String getInstanceId() {
			return instanceId;
		}

		public void setInstanceId(String instanceId) {
			this.instanceId = instanceId;
		}
	}
}
