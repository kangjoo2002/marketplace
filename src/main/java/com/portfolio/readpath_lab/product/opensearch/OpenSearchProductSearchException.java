package com.portfolio.readpath_lab.product.opensearch;

import com.portfolio.readpath_lab.product.application.ProductSearchFallbackMetrics.OpenSearchFailureReason;

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
