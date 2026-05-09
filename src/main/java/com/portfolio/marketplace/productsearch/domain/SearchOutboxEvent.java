package com.portfolio.marketplace.productsearch.domain;

public record SearchOutboxEvent(
		long id,
		long aggregateId,
		String eventType,
		int schemaVersion,
		String payload,
		int retryCount
) {

	public boolean isProductDeleteEvent() {
		return "PRODUCT_DELETED".equals(eventType);
	}
}
