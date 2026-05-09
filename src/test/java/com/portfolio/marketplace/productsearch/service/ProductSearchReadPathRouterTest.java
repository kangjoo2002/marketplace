package com.portfolio.marketplace.productsearch.service;

import com.portfolio.marketplace.productsearch.config.ProductSearchReadPathProperties;
import com.portfolio.marketplace.productsearch.domain.ProductSearchCondition;
import com.portfolio.marketplace.productsearch.domain.ProductSearchItem;
import com.portfolio.marketplace.productsearch.infrastructure.opensearch.OpenSearchProductSearchException;
import com.portfolio.marketplace.productsearch.repository.ProductSearchRepository;
import com.portfolio.marketplace.productsearch.service.port.ProductSearchIndexReader;
import java.time.Clock;
import java.time.Instant;
import java.time.ZoneId;
import java.util.List;
import org.junit.jupiter.api.Test;

import static com.portfolio.marketplace.productsearch.service.ProductSearchFallbackMetrics.OpenSearchFailureReason.CONNECTION_FAILURE;
import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.times;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

class ProductSearchReadPathRouterTest {

	@Test
	void dbReadPathIsDefault() {
		ProductSearchRepository repository = mock(ProductSearchRepository.class);
		ProductSearchIndexReader indexReader = mock(ProductSearchIndexReader.class);
		ProductSearchReadPathProperties properties = new ProductSearchReadPathProperties();
		ProductSearchFallbackMetrics metrics = new ProductSearchFallbackMetrics();
		ProductSearchCircuitBreaker circuitBreaker = new ProductSearchCircuitBreaker(properties, metrics);
		ProductSearchReadPathRouter router = new ProductSearchReadPathRouter(
				repository,
				indexReader,
				properties,
				metrics,
				circuitBreaker
		);
		ProductSearchCondition condition = new ProductSearchCondition();
		List<ProductSearchItem> dbItems = List.of();
		when(repository.search(any(ProductSearchCondition.class))).thenReturn(dbItems);

		List<ProductSearchItem> response = router.search(condition);

		assertThat(response).isSameAs(dbItems);
		assertThat(metrics.snapshot().fallbackCount()).isZero();
		verify(repository).search(any(ProductSearchCondition.class));
		verify(indexReader, never()).search(any(ProductSearchCondition.class));
	}

	@Test
	void opensearchReadPathUsesIndexReaderWhenFlagEnabled() {
		ProductSearchRepository repository = mock(ProductSearchRepository.class);
		ProductSearchIndexReader indexReader = mock(ProductSearchIndexReader.class);
		ProductSearchReadPathProperties properties = new ProductSearchReadPathProperties();
		properties.setReadPath("opensearch");
		ProductSearchFallbackMetrics metrics = new ProductSearchFallbackMetrics();
		ProductSearchCircuitBreaker circuitBreaker = new ProductSearchCircuitBreaker(properties, metrics);
		ProductSearchReadPathRouter router = new ProductSearchReadPathRouter(
				repository,
				indexReader,
				properties,
				metrics,
				circuitBreaker
		);
		ProductSearchCondition condition = new ProductSearchCondition();
		List<ProductSearchItem> searchItems = List.of();
		when(indexReader.search(any(ProductSearchCondition.class))).thenReturn(searchItems);

		List<ProductSearchItem> response = router.search(condition);

		assertThat(response).isSameAs(searchItems);
		assertThat(metrics.snapshot().fallbackCount()).isZero();
		assertThat(circuitBreaker.snapshot().state()).isEqualTo(ProductSearchCircuitBreaker.State.CLOSED);
		verify(indexReader).search(any(ProductSearchCondition.class));
		verify(repository, never()).search(any(ProductSearchCondition.class));
	}

	@Test
	void opensearchFailureFallsBackToDbAndRecordsMetrics() {
		ProductSearchRepository repository = mock(ProductSearchRepository.class);
		ProductSearchIndexReader indexReader = mock(ProductSearchIndexReader.class);
		ProductSearchReadPathProperties properties = new ProductSearchReadPathProperties();
		properties.setReadPath("opensearch");
		ProductSearchFallbackMetrics metrics = new ProductSearchFallbackMetrics();
		ProductSearchCircuitBreaker circuitBreaker = new ProductSearchCircuitBreaker(properties, metrics);
		ProductSearchReadPathRouter router = new ProductSearchReadPathRouter(
				repository,
				indexReader,
				properties,
				metrics,
				circuitBreaker
		);
		ProductSearchCondition condition = new ProductSearchCondition();
		List<ProductSearchItem> dbItems = List.of();
		when(indexReader.search(any(ProductSearchCondition.class)))
				.thenThrow(new OpenSearchProductSearchException(CONNECTION_FAILURE, "refused"));
		when(repository.search(any(ProductSearchCondition.class))).thenReturn(dbItems);

		List<ProductSearchItem> response = router.search(condition);

		assertThat(response).isSameAs(dbItems);
		assertThat(metrics.snapshot().fallbackCount()).isEqualTo(1);
		assertThat(metrics.snapshot().fallbackSuccessCount()).isEqualTo(1);
		assertThat(metrics.snapshot().openSearchFailureCount()).isEqualTo(1);
		assertThat(metrics.snapshot().timeoutCount()).isZero();
		verify(indexReader).search(any(ProductSearchCondition.class));
		verify(repository).search(any(ProductSearchCondition.class));
	}

	@Test
	void repeatedOpenSearchFailuresOpenCircuitBreakerAndShortCircuitNextRequest() {
		ProductSearchRepository repository = mock(ProductSearchRepository.class);
		ProductSearchIndexReader indexReader = mock(ProductSearchIndexReader.class);
		ProductSearchReadPathProperties properties = new ProductSearchReadPathProperties();
		properties.setReadPath("opensearch");
		properties.getOpenSearch().getCircuitBreaker().setFailureThreshold(2);
		ProductSearchFallbackMetrics metrics = new ProductSearchFallbackMetrics();
		ProductSearchCircuitBreaker circuitBreaker = new ProductSearchCircuitBreaker(properties, metrics);
		ProductSearchReadPathRouter router = new ProductSearchReadPathRouter(
				repository,
				indexReader,
				properties,
				metrics,
				circuitBreaker
		);
		ProductSearchCondition condition = new ProductSearchCondition();
		List<ProductSearchItem> dbItems = List.of();
		when(indexReader.search(any(ProductSearchCondition.class)))
				.thenThrow(new OpenSearchProductSearchException(CONNECTION_FAILURE, "refused"));
		when(repository.search(any(ProductSearchCondition.class))).thenReturn(dbItems);

		router.search(condition);
		router.search(condition);
		List<ProductSearchItem> shortCircuitedResponse = router.search(condition);

		assertThat(shortCircuitedResponse).isSameAs(dbItems);
		assertThat(circuitBreaker.snapshot().state()).isEqualTo(ProductSearchCircuitBreaker.State.OPEN);
		assertThat(metrics.snapshot().fallbackCount()).isEqualTo(3);
		assertThat(metrics.snapshot().fallbackSuccessCount()).isEqualTo(3);
		assertThat(metrics.snapshot().openSearchFailureCount()).isEqualTo(2);
		assertThat(metrics.snapshot().circuitBreakerOpenCount()).isEqualTo(1);
		assertThat(metrics.snapshot().shortCircuitedRequestCount()).isEqualTo(1);
		verify(indexReader, times(2)).search(any(ProductSearchCondition.class));
		verify(repository, times(3)).search(any(ProductSearchCondition.class));
	}

	@Test
	void halfOpenSuccessClosesCircuitBreaker() {
		ProductSearchRepository repository = mock(ProductSearchRepository.class);
		ProductSearchIndexReader indexReader = mock(ProductSearchIndexReader.class);
		ProductSearchReadPathProperties properties = new ProductSearchReadPathProperties();
		properties.setReadPath("opensearch");
		properties.getOpenSearch().getCircuitBreaker().setFailureThreshold(1);
		properties.getOpenSearch().getCircuitBreaker().setOpenWaitMs(1000);
		ProductSearchFallbackMetrics metrics = new ProductSearchFallbackMetrics();
		MutableClock clock = new MutableClock();
		ProductSearchCircuitBreaker circuitBreaker = new ProductSearchCircuitBreaker(properties, metrics, clock);
		ProductSearchReadPathRouter router = new ProductSearchReadPathRouter(
				repository,
				indexReader,
				properties,
				metrics,
				circuitBreaker
		);
		ProductSearchCondition condition = new ProductSearchCondition();
		List<ProductSearchItem> dbItems = List.of();
		List<ProductSearchItem> searchItems = List.of();
		when(indexReader.search(any(ProductSearchCondition.class)))
				.thenThrow(new OpenSearchProductSearchException(CONNECTION_FAILURE, "refused"))
				.thenReturn(searchItems);
		when(repository.search(any(ProductSearchCondition.class))).thenReturn(dbItems);

		router.search(condition);
		clock.advanceMillis(1000);
		List<ProductSearchItem> recoveredResponse = router.search(condition);

		assertThat(recoveredResponse).isSameAs(searchItems);
		assertThat(circuitBreaker.snapshot().state()).isEqualTo(ProductSearchCircuitBreaker.State.CLOSED);
		assertThat(metrics.snapshot().halfOpenAttemptCount()).isEqualTo(1);
		assertThat(metrics.snapshot().halfOpenSuccessCount()).isEqualTo(1);
		assertThat(metrics.snapshot().halfOpenFailureCount()).isZero();
		verify(indexReader, times(2)).search(any(ProductSearchCondition.class));
		verify(repository).search(any(ProductSearchCondition.class));
	}

	@Test
	void halfOpenFailureReopensCircuitBreaker() {
		ProductSearchRepository repository = mock(ProductSearchRepository.class);
		ProductSearchIndexReader indexReader = mock(ProductSearchIndexReader.class);
		ProductSearchReadPathProperties properties = new ProductSearchReadPathProperties();
		properties.setReadPath("opensearch");
		properties.getOpenSearch().getCircuitBreaker().setFailureThreshold(1);
		properties.getOpenSearch().getCircuitBreaker().setOpenWaitMs(1000);
		ProductSearchFallbackMetrics metrics = new ProductSearchFallbackMetrics();
		MutableClock clock = new MutableClock();
		ProductSearchCircuitBreaker circuitBreaker = new ProductSearchCircuitBreaker(properties, metrics, clock);
		ProductSearchReadPathRouter router = new ProductSearchReadPathRouter(
				repository,
				indexReader,
				properties,
				metrics,
				circuitBreaker
		);
		ProductSearchCondition condition = new ProductSearchCondition();
		List<ProductSearchItem> dbItems = List.of();
		when(indexReader.search(any(ProductSearchCondition.class)))
				.thenThrow(new OpenSearchProductSearchException(CONNECTION_FAILURE, "refused"));
		when(repository.search(any(ProductSearchCondition.class))).thenReturn(dbItems);

		router.search(condition);
		clock.advanceMillis(1000);
		router.search(condition);
		router.search(condition);

		assertThat(circuitBreaker.snapshot().state()).isEqualTo(ProductSearchCircuitBreaker.State.OPEN);
		assertThat(metrics.snapshot().circuitBreakerOpenCount()).isEqualTo(2);
		assertThat(metrics.snapshot().shortCircuitedRequestCount()).isEqualTo(1);
		assertThat(metrics.snapshot().halfOpenAttemptCount()).isEqualTo(1);
		assertThat(metrics.snapshot().halfOpenSuccessCount()).isZero();
		assertThat(metrics.snapshot().halfOpenFailureCount()).isEqualTo(1);
		verify(indexReader, times(2)).search(any(ProductSearchCondition.class));
		verify(repository, times(3)).search(any(ProductSearchCondition.class));
	}

	@Test
	void indexReaderClientErrorDoesNotFallbackOrOpenCircuitBreaker() {
		ProductSearchRepository repository = mock(ProductSearchRepository.class);
		ProductSearchIndexReader indexReader = mock(ProductSearchIndexReader.class);
		ProductSearchReadPathProperties properties = new ProductSearchReadPathProperties();
		properties.setReadPath("opensearch");
		ProductSearchFallbackMetrics metrics = new ProductSearchFallbackMetrics();
		ProductSearchCircuitBreaker circuitBreaker = new ProductSearchCircuitBreaker(properties, metrics);
		ProductSearchReadPathRouter router = new ProductSearchReadPathRouter(
				repository,
				indexReader,
				properties,
				metrics,
				circuitBreaker
		);
		ProductSearchCondition condition = new ProductSearchCondition();
		when(indexReader.search(any(ProductSearchCondition.class)))
				.thenThrow(new IllegalArgumentException("Unsupported sort: ratingDesc"));

		assertThatThrownBy(() -> router.search(condition))
				.isInstanceOf(IllegalArgumentException.class);

		assertThat(circuitBreaker.snapshot().state()).isEqualTo(ProductSearchCircuitBreaker.State.CLOSED);
		assertThat(metrics.snapshot().fallbackCount()).isZero();
		assertThat(metrics.snapshot().openSearchFailureCount()).isZero();
		verify(repository, never()).search(any(ProductSearchCondition.class));
	}

	private static class MutableClock extends Clock {

		private Instant instant = Instant.parse("2026-05-02T00:00:00Z");

		void advanceMillis(long millis) {
			instant = instant.plusMillis(millis);
		}

		@Override
		public ZoneId getZone() {
			return ZoneId.of("UTC");
		}

		@Override
		public Clock withZone(ZoneId zone) {
			return this;
		}

		@Override
		public Instant instant() {
			return instant;
		}
	}
}
