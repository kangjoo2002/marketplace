package com.portfolio.readpath_lab.product.application;

import java.util.concurrent.atomic.AtomicLong;
import org.springframework.stereotype.Component;

@Component
public class ProductSearchFallbackMetrics {

	private final AtomicLong fallbackCount = new AtomicLong();
	private final AtomicLong fallbackSuccessCount = new AtomicLong();
	private final AtomicLong timeoutCount = new AtomicLong();
	private final AtomicLong openSearchFailureCount = new AtomicLong();
	private final AtomicLong invalidSearchResponseCount = new AtomicLong();

	public void recordFallback(OpenSearchFailureReason reason) {
		fallbackCount.incrementAndGet();
		openSearchFailureCount.incrementAndGet();
		if (reason == OpenSearchFailureReason.TIMEOUT) {
			timeoutCount.incrementAndGet();
		}
		if (reason == OpenSearchFailureReason.MALFORMED_RESPONSE) {
			invalidSearchResponseCount.incrementAndGet();
		}
	}

	public void recordFallbackSuccess() {
		fallbackSuccessCount.incrementAndGet();
	}

	public Snapshot snapshot() {
		return new Snapshot(
				fallbackCount.get(),
				fallbackSuccessCount.get(),
				timeoutCount.get(),
				openSearchFailureCount.get(),
				invalidSearchResponseCount.get()
		);
	}

	public enum OpenSearchFailureReason {
		TIMEOUT,
		HTTP_5XX,
		CONNECTION_FAILURE,
		MALFORMED_RESPONSE
	}

	public record Snapshot(
			long fallbackCount,
			long fallbackSuccessCount,
			long timeoutCount,
			long openSearchFailureCount,
			long invalidSearchResponseCount
	) {
	}
}
