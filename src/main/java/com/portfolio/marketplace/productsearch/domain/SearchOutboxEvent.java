package com.portfolio.marketplace.productsearch.domain;

import java.time.OffsetDateTime;

public record SearchOutboxEvent(
		long id,
		long aggregateId,
		String eventType,
		int schemaVersion,
		String payload,
		int retryCount,
		String claimToken,
		OffsetDateTime createdAt,
		OffsetDateTime claimedAt
) {

	public boolean isProductDeleteEvent() {
		return "PRODUCT_DELETED".equals(eventType);
	}
}
