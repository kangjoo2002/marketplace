package com.portfolio.marketplace.productsearch.infrastructure.opensearch;

import com.portfolio.marketplace.productsearch.service.ProductSearchFallbackMetrics.OpenSearchFailureReason;

public class OpenSearchProductSearchException extends RuntimeException {

	private final OpenSearchFailureReason reason;

	public OpenSearchProductSearchException(OpenSearchFailureReason reason, String message, Throwable cause) {
		super(message, cause);
		this.reason = reason;
	}

	public OpenSearchProductSearchException(OpenSearchFailureReason reason, String message) {
		super(message);
		this.reason = reason;
	}

	public OpenSearchFailureReason getReason() {
		return reason;
	}
}



