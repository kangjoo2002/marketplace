package com.portfolio.readpath_lab.product.application;

import com.portfolio.readpath_lab.product.api.ProductSearchItemResponse;
import com.portfolio.readpath_lab.product.api.ProductSearchRequest;
import com.portfolio.readpath_lab.product.api.ProductSearchResponse;
import com.portfolio.readpath_lab.product.opensearch.OpenSearchProductSearchAdapter;
import com.portfolio.readpath_lab.product.opensearch.OpenSearchProductSearchException;
import com.portfolio.readpath_lab.product.repository.ProductSearchRepository;
import java.util.List;
import org.junit.jupiter.api.Test;

import static com.portfolio.readpath_lab.product.application.ProductSearchFallbackMetrics.OpenSearchFailureReason.CONNECTION_FAILURE;
import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

class ProductSearchServiceTest {

	@Test
	void dbReadPathIsDefault() {
		ProductSearchRepository repository = mock(ProductSearchRepository.class);
		OpenSearchProductSearchAdapter adapter = mock(OpenSearchProductSearchAdapter.class);
		ProductSearchReadPathProperties properties = new ProductSearchReadPathProperties();
		ProductSearchFallbackMetrics metrics = new ProductSearchFallbackMetrics();
		ProductSearchService service = new ProductSearchService(repository, adapter, properties, metrics);
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
		ProductSearchService service = new ProductSearchService(repository, adapter, properties, metrics);
		ProductSearchRequest request = new ProductSearchRequest();
		List<ProductSearchItemResponse> searchItems = List.of();
		when(adapter.search(request)).thenReturn(searchItems);

		ProductSearchResponse response = service.search(request);

		assertThat(response.items()).isSameAs(searchItems);
		assertThat(metrics.snapshot().fallbackCount()).isZero();
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
		ProductSearchService service = new ProductSearchService(repository, adapter, properties, metrics);
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
}
