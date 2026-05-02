package com.portfolio.readpath_lab.product.application;

import java.time.Clock;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.stereotype.Component;

@Component
public class ProductSearchCircuitBreaker {

	private static final Logger log = LoggerFactory.getLogger(ProductSearchCircuitBreaker.class);

	private final ProductSearchReadPathProperties readPathProperties;
	private final ProductSearchFallbackMetrics fallbackMetrics;
	private final Clock clock;

	private State state = State.CLOSED;
	private int consecutiveFailures;
	private long openedAtMs;
	private int halfOpenInFlight;

	@Autowired
	public ProductSearchCircuitBreaker(
			ProductSearchReadPathProperties readPathProperties,
			ProductSearchFallbackMetrics fallbackMetrics
	) {
		this(readPathProperties, fallbackMetrics, Clock.systemUTC());
	}

	ProductSearchCircuitBreaker(
			ProductSearchReadPathProperties readPathProperties,
			ProductSearchFallbackMetrics fallbackMetrics,
			Clock clock
	) {
		this.readPathProperties = readPathProperties;
		this.fallbackMetrics = fallbackMetrics;
		this.clock = clock;
	}

	public synchronized boolean tryAcquirePermission() {
		if (!config().isEnabled()) {
			return true;
		}

		long nowMs = clock.millis();
		if (state == State.OPEN && nowMs - openedAtMs >= openWaitMs()) {
			state = State.HALF_OPEN;
			halfOpenInFlight = 0;
		}

		if (state == State.OPEN) {
			fallbackMetrics.recordShortCircuitedRequest();
			log.warn(
					"product_search_opensearch_circuit_breaker_short_circuit state={} shortCircuitedRequestCount={}",
					state,
					fallbackMetrics.snapshot().shortCircuitedRequestCount()
			);
			return false;
		}

		if (state == State.HALF_OPEN) {
			if (halfOpenInFlight >= halfOpenPermittedCalls()) {
				fallbackMetrics.recordShortCircuitedRequest();
				log.warn(
						"product_search_opensearch_circuit_breaker_short_circuit state={} shortCircuitedRequestCount={}",
						state,
						fallbackMetrics.snapshot().shortCircuitedRequestCount()
				);
				return false;
			}
			halfOpenInFlight++;
			fallbackMetrics.recordHalfOpenAttempt();
			log.info(
					"product_search_opensearch_circuit_breaker_half_open_attempt halfOpenAttemptCount={}",
					fallbackMetrics.snapshot().halfOpenAttemptCount()
			);
		}

		return true;
	}

	public synchronized void recordSuccess() {
		if (!config().isEnabled()) {
			return;
		}

		if (state == State.HALF_OPEN) {
			fallbackMetrics.recordHalfOpenSuccess();
			log.info(
					"product_search_opensearch_circuit_breaker_closed halfOpenSuccessCount={}",
					fallbackMetrics.snapshot().halfOpenSuccessCount()
			);
		}
		state = State.CLOSED;
		consecutiveFailures = 0;
		halfOpenInFlight = 0;
	}

	public synchronized void recordFailure() {
		if (!config().isEnabled()) {
			return;
		}

		if (state == State.HALF_OPEN) {
			fallbackMetrics.recordHalfOpenFailure();
			open();
			log.warn(
					"product_search_opensearch_circuit_breaker_half_open_failure halfOpenFailureCount={}",
					fallbackMetrics.snapshot().halfOpenFailureCount()
			);
			return;
		}

		if (state == State.CLOSED) {
			consecutiveFailures++;
			if (consecutiveFailures >= failureThreshold()) {
				open();
			}
		}
	}

	public synchronized Snapshot snapshot() {
		return new Snapshot(
				config().isEnabled(),
				state,
				failureThreshold(),
				openWaitMs(),
				halfOpenPermittedCalls(),
				consecutiveFailures
		);
	}

	private void open() {
		state = State.OPEN;
		openedAtMs = clock.millis();
		consecutiveFailures = 0;
		halfOpenInFlight = 0;
		fallbackMetrics.recordCircuitBreakerOpen();
		log.warn(
				"product_search_opensearch_circuit_breaker_open openCount={}",
				fallbackMetrics.snapshot().circuitBreakerOpenCount()
		);
	}

	private ProductSearchReadPathProperties.CircuitBreaker config() {
		return readPathProperties.getOpenSearch().getCircuitBreaker();
	}

	private int failureThreshold() {
		return Math.max(1, config().getFailureThreshold());
	}

	private long openWaitMs() {
		return Math.max(0, config().getOpenWaitMs());
	}

	private int halfOpenPermittedCalls() {
		return Math.max(1, config().getHalfOpenPermittedCalls());
	}

	public enum State {
		CLOSED,
		OPEN,
		HALF_OPEN
	}

	public record Snapshot(
			boolean enabled,
			State state,
			int failureThreshold,
			long openWaitMs,
			int halfOpenPermittedCalls,
			int consecutiveFailures
	) {
	}
}
