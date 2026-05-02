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
	private final AtomicLong circuitBreakerOpenCount = new AtomicLong();
	private final AtomicLong shortCircuitedRequestCount = new AtomicLong();
	private final AtomicLong halfOpenAttemptCount = new AtomicLong();
	private final AtomicLong halfOpenSuccessCount = new AtomicLong();
	private final AtomicLong halfOpenFailureCount = new AtomicLong();

	public void recordFallback(OpenSearchFailureReason reason) {
		fallbackCount.incrementAndGet();
		if (reason != OpenSearchFailureReason.CIRCUIT_OPEN) {
			openSearchFailureCount.incrementAndGet();
		}
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

	public void recordCircuitBreakerOpen() {
		circuitBreakerOpenCount.incrementAndGet();
	}

	public void recordShortCircuitedRequest() {
		shortCircuitedRequestCount.incrementAndGet();
	}

	public void recordHalfOpenAttempt() {
		halfOpenAttemptCount.incrementAndGet();
	}

	public void recordHalfOpenSuccess() {
		halfOpenSuccessCount.incrementAndGet();
	}

	public void recordHalfOpenFailure() {
		halfOpenFailureCount.incrementAndGet();
	}

	public Snapshot snapshot() {
		return new Snapshot(
				fallbackCount.get(),
				fallbackSuccessCount.get(),
				timeoutCount.get(),
				openSearchFailureCount.get(),
				invalidSearchResponseCount.get(),
				circuitBreakerOpenCount.get(),
				shortCircuitedRequestCount.get(),
				halfOpenAttemptCount.get(),
				halfOpenSuccessCount.get(),
				halfOpenFailureCount.get()
		);
	}

	public enum OpenSearchFailureReason {
		TIMEOUT,
		HTTP_5XX,
		CONNECTION_FAILURE,
		MALFORMED_RESPONSE,
		CIRCUIT_OPEN
	}

	public record Snapshot(
			long fallbackCount,
			long fallbackSuccessCount,
			long timeoutCount,
			long openSearchFailureCount,
			long invalidSearchResponseCount,
			long circuitBreakerOpenCount,
			long shortCircuitedRequestCount,
			long halfOpenAttemptCount,
			long halfOpenSuccessCount,
			long halfOpenFailureCount
	) {
	}
}
