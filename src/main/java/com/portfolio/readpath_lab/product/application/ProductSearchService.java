package com.portfolio.readpath_lab.product.application;

import com.portfolio.readpath_lab.product.api.ProductSearchRequest;
import com.portfolio.readpath_lab.product.api.ProductSearchResponse;
import com.portfolio.readpath_lab.product.opensearch.OpenSearchProductSearchAdapter;
import com.portfolio.readpath_lab.product.opensearch.OpenSearchProductSearchException;
import com.portfolio.readpath_lab.product.repository.ProductSearchRepository;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Service;

@Service
public class ProductSearchService {

	private static final Logger log = LoggerFactory.getLogger(ProductSearchService.class);

	private final ProductSearchRepository productSearchRepository;
	private final OpenSearchProductSearchAdapter openSearchProductSearchAdapter;
	private final ProductSearchReadPathProperties readPathProperties;
	private final ProductSearchFallbackMetrics fallbackMetrics;
	private final ProductSearchCircuitBreaker circuitBreaker;

	public ProductSearchService(
			ProductSearchRepository productSearchRepository,
			OpenSearchProductSearchAdapter openSearchProductSearchAdapter,
			ProductSearchReadPathProperties readPathProperties,
			ProductSearchFallbackMetrics fallbackMetrics,
			ProductSearchCircuitBreaker circuitBreaker
	) {
		this.productSearchRepository = productSearchRepository;
		this.openSearchProductSearchAdapter = openSearchProductSearchAdapter;
		this.readPathProperties = readPathProperties;
		this.fallbackMetrics = fallbackMetrics;
		this.circuitBreaker = circuitBreaker;
	}

	public ProductSearchResponse search(ProductSearchRequest request) {
		readPathProperties.normalizedReadPath();
		if (readPathProperties.isOpenSearchReadPath()) {
			if (!circuitBreaker.tryAcquirePermission()) {
				fallbackMetrics.recordFallback(ProductSearchFallbackMetrics.OpenSearchFailureReason.CIRCUIT_OPEN);
				log.warn(
						"product_search_opensearch_fallback reason={} fallbackCount={}",
						ProductSearchFallbackMetrics.OpenSearchFailureReason.CIRCUIT_OPEN,
						fallbackMetrics.snapshot().fallbackCount()
				);
				return recordFallbackSuccess(searchDbFallback(request));
			}

			try {
				ProductSearchResponse response = ProductSearchResponse.of(
						openSearchProductSearchAdapter.search(request),
						request.getLimit(),
						request.getOffset()
				);
				circuitBreaker.recordSuccess();
				return response;
			} catch (OpenSearchProductSearchException exception) {
				fallbackMetrics.recordFallback(exception.getReason());
				circuitBreaker.recordFailure();
				log.warn(
						"product_search_opensearch_fallback reason={} fallbackCount={}",
						exception.getReason(),
						fallbackMetrics.snapshot().fallbackCount()
				);

				return recordFallbackSuccess(searchDbFallback(request));
			}
		}

		return ProductSearchResponse.of(
				productSearchRepository.search(request),
				request.getLimit(),
				request.getOffset()
		);
	}

	private ProductSearchResponse searchDbFallback(ProductSearchRequest request) {
		return ProductSearchResponse.of(
				productSearchRepository.search(request),
				request.getLimit(),
				request.getOffset()
		);
	}

	private ProductSearchResponse recordFallbackSuccess(ProductSearchResponse response) {
		fallbackMetrics.recordFallbackSuccess();
		log.info(
				"product_search_db_fallback_success fallbackSuccessCount={}",
				fallbackMetrics.snapshot().fallbackSuccessCount()
		);
		return response;
	}

	public ProductSearchResponse searchDbTuned(ProductSearchRequest request) {
		return ProductSearchResponse.of(
				productSearchRepository.searchDbTuned(request),
				request.getLimit(),
				request.getOffset()
		);
	}

	public ProductSearchResponse searchDenormalizedDb(ProductSearchRequest request) {
		return ProductSearchResponse.of(
				productSearchRepository.searchDenormalizedDb(request),
				request.getLimit(),
				request.getOffset()
		);
	}
}
