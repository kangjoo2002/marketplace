package com.portfolio.readpath_lab.product.application;

import com.portfolio.readpath_lab.product.api.ProductSearchItemResponse;
import com.portfolio.readpath_lab.product.api.ProductSearchRequest;
import com.portfolio.readpath_lab.product.api.ProductSearchResponse;
import com.portfolio.readpath_lab.product.opensearch.OpenSearchProductSearchAdapter;
import com.portfolio.readpath_lab.product.opensearch.OpenSearchProductSearchException;
import com.portfolio.readpath_lab.product.repository.ProductSearchRepository;
import java.time.Clock;
import java.time.Instant;
import java.time.ZoneId;
import java.util.List;
import org.junit.jupiter.api.Test;

import static com.portfolio.readpath_lab.product.application.ProductSearchFallbackMetrics.OpenSearchFailureReason.CONNECTION_FAILURE;
import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.times;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

class ProductSearchServiceTest {

	@Test
	void dbReadPathIsDefault() {
		ProductSearchRepository repository = mock(ProductSearchRepository.class);
		OpenSearchProductSearchAdapter adapter = mock(OpenSearchProductSearchAdapter.class);
		ProductSearchReadPathProperties properties = new ProductSearchReadPathProperties();
		ProductSearchFallbackMetrics metrics = new ProductSearchFallbackMetrics();
		ProductSearchCircuitBreaker circuitBreaker = new ProductSearchCircuitBreaker(properties, metrics);
		ProductSearchService service = new ProductSearchService(repository, adapter, properties, metrics, circuitBreaker);
		ProductSearchRequest request = new ProductSearchRequest();
		List<ProductSearchItemResponse> dbItems = List.of();
		when(repository.search(request)).thenReturn(dbItems);

		ProductSearchResponse response = service.search(request);

		assertThat(response.items()).isSameAs(dbItems);
		assertThat(metrics.snapshot().fallbackCount()).isZero();
		verify(repository).search(request);
		verify(adapter, never()).search(request);
	}

	@Test
	void opensearchReadPathUsesAdapterWhenFlagEnabled() {
		ProductSearchRepository repository = mock(ProductSearchRepository.class);
		OpenSearchProductSearchAdapter adapter = mock(OpenSearchProductSearchAdapter.class);
		ProductSearchReadPathProperties properties = new ProductSearchReadPathProperties();
		properties.setReadPath("opensearch");
		ProductSearchFallbackMetrics metrics = new ProductSearchFallbackMetrics();
		ProductSearchCircuitBreaker circuitBreaker = new ProductSearchCircuitBreaker(properties, metrics);
		ProductSearchService service = new ProductSearchService(repository, adapter, properties, metrics, circuitBreaker);
		ProductSearchRequest request = new ProductSearchRequest();
		List<ProductSearchItemResponse> searchItems = List.of();
		when(adapter.search(request)).thenReturn(searchItems);

		ProductSearchResponse response = service.search(request);

		assertThat(response.items()).isSameAs(searchItems);
		assertThat(metrics.snapshot().fallbackCount()).isZero();
		assertThat(circuitBreaker.snapshot().state()).isEqualTo(ProductSearchCircuitBreaker.State.CLOSED);
		verify(adapter).search(request);
		verify(repository, never()).search(request);
	}

	@Test
	void opensearchFailureFallsBackToDbAndRecordsMetrics() {
		ProductSearchRepository repository = mock(ProductSearchRepository.class);
		OpenSearchProductSearchAdapter adapter = mock(OpenSearchProductSearchAdapter.class);
		ProductSearchReadPathProperties properties = new ProductSearchReadPathProperties();
		properties.setReadPath("opensearch");
		ProductSearchFallbackMetrics metrics = new ProductSearchFallbackMetrics();
		ProductSearchCircuitBreaker circuitBreaker = new ProductSearchCircuitBreaker(properties, metrics);
		ProductSearchService service = new ProductSearchService(repository, adapter, properties, metrics, circuitBreaker);
		ProductSearchRequest request = new ProductSearchRequest();
		List<ProductSearchItemResponse> dbItems = List.of();
		when(adapter.search(request)).thenThrow(new OpenSearchProductSearchException(CONNECTION_FAILURE, "refused"));
		when(repository.search(request)).thenReturn(dbItems);

		ProductSearchResponse response = service.search(request);

		assertThat(response.items()).isSameAs(dbItems);
		assertThat(metrics.snapshot().fallbackCount()).isEqualTo(1);
		assertThat(metrics.snapshot().fallbackSuccessCount()).isEqualTo(1);
		assertThat(metrics.snapshot().openSearchFailureCount()).isEqualTo(1);
		assertThat(metrics.snapshot().timeoutCount()).isZero();
		verify(adapter).search(request);
		verify(repository).search(request);
	}

	@Test
	void repeatedOpenSearchFailuresOpenCircuitBreakerAndShortCircuitNextRequest() {
		ProductSearchRepository repository = mock(ProductSearchRepository.class);
		OpenSearchProductSearchAdapter adapter = mock(OpenSearchProductSearchAdapter.class);
		ProductSearchReadPathProperties properties = new ProductSearchReadPathProperties();
		properties.setReadPath("opensearch");
		properties.getOpenSearch().getCircuitBreaker().setFailureThreshold(2);
		ProductSearchFallbackMetrics metrics = new ProductSearchFallbackMetrics();
		ProductSearchCircuitBreaker circuitBreaker = new ProductSearchCircuitBreaker(properties, metrics);
		ProductSearchService service = new ProductSearchService(repository, adapter, properties, metrics, circuitBreaker);
		ProductSearchRequest request = new ProductSearchRequest();
		List<ProductSearchItemResponse> dbItems = List.of();
		when(adapter.search(request)).thenThrow(new OpenSearchProductSearchException(CONNECTION_FAILURE, "refused"));
		when(repository.search(request)).thenReturn(dbItems);

		service.search(request);
		service.search(request);
		ProductSearchResponse shortCircuitedResponse = service.search(request);

		assertThat(shortCircuitedResponse.items()).isSameAs(dbItems);
		assertThat(circuitBreaker.snapshot().state()).isEqualTo(ProductSearchCircuitBreaker.State.OPEN);
		assertThat(metrics.snapshot().fallbackCount()).isEqualTo(3);
		assertThat(metrics.snapshot().fallbackSuccessCount()).isEqualTo(3);
		assertThat(metrics.snapshot().openSearchFailureCount()).isEqualTo(2);
		assertThat(metrics.snapshot().circuitBreakerOpenCount()).isEqualTo(1);
		assertThat(metrics.snapshot().shortCircuitedRequestCount()).isEqualTo(1);
		verify(adapter, times(2)).search(request);
		verify(repository, times(3)).search(request);
	}

	@Test
	void halfOpenSuccessClosesCircuitBreaker() {
		ProductSearchRepository repository = mock(ProductSearchRepository.class);
		OpenSearchProductSearchAdapter adapter = mock(OpenSearchProductSearchAdapter.class);
		ProductSearchReadPathProperties properties = new ProductSearchReadPathProperties();
		properties.setReadPath("opensearch");
		properties.getOpenSearch().getCircuitBreaker().setFailureThreshold(1);
		properties.getOpenSearch().getCircuitBreaker().setOpenWaitMs(1000);
		ProductSearchFallbackMetrics metrics = new ProductSearchFallbackMetrics();
		MutableClock clock = new MutableClock();
		ProductSearchCircuitBreaker circuitBreaker = new ProductSearchCircuitBreaker(properties, metrics, clock);
		ProductSearchService service = new ProductSearchService(repository, adapter, properties, metrics, circuitBreaker);
		ProductSearchRequest request = new ProductSearchRequest();
		List<ProductSearchItemResponse> dbItems = List.of();
		List<ProductSearchItemResponse> searchItems = List.of();
		when(adapter.search(request))
				.thenThrow(new OpenSearchProductSearchException(CONNECTION_FAILURE, "refused"))
				.thenReturn(searchItems);
		when(repository.search(request)).thenReturn(dbItems);

		service.search(request);
		clock.advanceMillis(1000);
		ProductSearchResponse recoveredResponse = service.search(request);

		assertThat(recoveredResponse.items()).isSameAs(searchItems);
		assertThat(circuitBreaker.snapshot().state()).isEqualTo(ProductSearchCircuitBreaker.State.CLOSED);
		assertThat(metrics.snapshot().halfOpenAttemptCount()).isEqualTo(1);
		assertThat(metrics.snapshot().halfOpenSuccessCount()).isEqualTo(1);
		assertThat(metrics.snapshot().halfOpenFailureCount()).isZero();
		verify(adapter, times(2)).search(request);
		verify(repository).search(request);
	}

	@Test
	void halfOpenFailureReopensCircuitBreaker() {
		ProductSearchRepository repository = mock(ProductSearchRepository.class);
		OpenSearchProductSearchAdapter adapter = mock(OpenSearchProductSearchAdapter.class);
		ProductSearchReadPathProperties properties = new ProductSearchReadPathProperties();
		properties.setReadPath("opensearch");
		properties.getOpenSearch().getCircuitBreaker().setFailureThreshold(1);
		properties.getOpenSearch().getCircuitBreaker().setOpenWaitMs(1000);
		ProductSearchFallbackMetrics metrics = new ProductSearchFallbackMetrics();
		MutableClock clock = new MutableClock();
		ProductSearchCircuitBreaker circuitBreaker = new ProductSearchCircuitBreaker(properties, metrics, clock);
		ProductSearchService service = new ProductSearchService(repository, adapter, properties, metrics, circuitBreaker);
		ProductSearchRequest request = new ProductSearchRequest();
		List<ProductSearchItemResponse> dbItems = List.of();
		when(adapter.search(request)).thenThrow(new OpenSearchProductSearchException(CONNECTION_FAILURE, "refused"));
		when(repository.search(request)).thenReturn(dbItems);

		service.search(request);
		clock.advanceMillis(1000);
		service.search(request);
		service.search(request);

		assertThat(circuitBreaker.snapshot().state()).isEqualTo(ProductSearchCircuitBreaker.State.OPEN);
		assertThat(metrics.snapshot().circuitBreakerOpenCount()).isEqualTo(2);
		assertThat(metrics.snapshot().shortCircuitedRequestCount()).isEqualTo(1);
		assertThat(metrics.snapshot().halfOpenAttemptCount()).isEqualTo(1);
		assertThat(metrics.snapshot().halfOpenSuccessCount()).isZero();
		assertThat(metrics.snapshot().halfOpenFailureCount()).isEqualTo(1);
		verify(adapter, times(2)).search(request);
		verify(repository, times(3)).search(request);
	}

	@Test
	void adapterClientErrorDoesNotFallbackOrOpenCircuitBreaker() {
		ProductSearchRepository repository = mock(ProductSearchRepository.class);
		OpenSearchProductSearchAdapter adapter = mock(OpenSearchProductSearchAdapter.class);
		ProductSearchReadPathProperties properties = new ProductSearchReadPathProperties();
		properties.setReadPath("opensearch");
		ProductSearchFallbackMetrics metrics = new ProductSearchFallbackMetrics();
		ProductSearchCircuitBreaker circuitBreaker = new ProductSearchCircuitBreaker(properties, metrics);
		ProductSearchService service = new ProductSearchService(repository, adapter, properties, metrics, circuitBreaker);
		ProductSearchRequest request = new ProductSearchRequest();
		when(adapter.search(request)).thenThrow(new IllegalArgumentException("Unsupported sort: ratingDesc"));

		assertThatThrownBy(() -> service.search(request))
				.isInstanceOf(IllegalArgumentException.class);

		assertThat(circuitBreaker.snapshot().state()).isEqualTo(ProductSearchCircuitBreaker.State.CLOSED);
		assertThat(metrics.snapshot().fallbackCount()).isZero();
		assertThat(metrics.snapshot().openSearchFailureCount()).isZero();
		verify(repository, never()).search(request);
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
