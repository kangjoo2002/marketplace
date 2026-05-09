package com.portfolio.marketplace.productsearch.service;

import com.portfolio.marketplace.productsearch.config.ProductSearchReadPathProperties;
import com.portfolio.marketplace.productsearch.domain.ProductSearchCondition;
import com.portfolio.marketplace.productsearch.domain.ProductSearchItem;
import com.portfolio.marketplace.productsearch.infrastructure.opensearch.OpenSearchProductSearchException;
import com.portfolio.marketplace.productsearch.repository.ProductSearchRepository;
import com.portfolio.marketplace.productsearch.service.port.ProductSearchIndexReader;
import java.util.List;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Component;

@Component
public class ProductSearchReadPathRouter {

	private static final Logger log = LoggerFactory.getLogger(ProductSearchReadPathRouter.class);

	private final ProductSearchRepository productSearchRepository;
	private final ProductSearchIndexReader productSearchIndexReader;
	private final ProductSearchReadPathProperties readPathProperties;
	private final ProductSearchFallbackMetrics fallbackMetrics;
	private final ProductSearchCircuitBreaker circuitBreaker;

	public ProductSearchReadPathRouter(
			ProductSearchRepository productSearchRepository,
			ProductSearchIndexReader productSearchIndexReader,
			ProductSearchReadPathProperties readPathProperties,
			ProductSearchFallbackMetrics fallbackMetrics,
			ProductSearchCircuitBreaker circuitBreaker
	) {
		this.productSearchRepository = productSearchRepository;
		this.productSearchIndexReader = productSearchIndexReader;
		this.readPathProperties = readPathProperties;
		this.fallbackMetrics = fallbackMetrics;
		this.circuitBreaker = circuitBreaker;
	}

	public List<ProductSearchItem> search(ProductSearchCondition condition) {
		readPathProperties.normalizedReadPath();
		if (!readPathProperties.isOpenSearchReadPath()) {
			return productSearchRepository.search(condition);
		}

		if (!circuitBreaker.tryAcquirePermission()) {
			fallbackMetrics.recordFallback(ProductSearchFallbackMetrics.OpenSearchFailureReason.CIRCUIT_OPEN);
			log.warn(
					"product_search_opensearch_fallback reason={} fallbackCount={}",
					ProductSearchFallbackMetrics.OpenSearchFailureReason.CIRCUIT_OPEN,
					fallbackMetrics.snapshot().fallbackCount()
			);
			return recordFallbackSuccess(productSearchRepository.search(condition));
		}

		try {
			List<ProductSearchItem> items = productSearchIndexReader.search(condition);
			circuitBreaker.recordSuccess();
			return items;
		} catch (OpenSearchProductSearchException exception) {
			fallbackMetrics.recordFallback(exception.getReason());
			circuitBreaker.recordFailure();
			log.warn(
					"product_search_opensearch_fallback reason={} fallbackCount={}",
					exception.getReason(),
					fallbackMetrics.snapshot().fallbackCount()
			);
			return recordFallbackSuccess(productSearchRepository.search(condition));
		}
	}

	private List<ProductSearchItem> recordFallbackSuccess(List<ProductSearchItem> items) {
		fallbackMetrics.recordFallbackSuccess();
		log.info(
				"product_search_db_fallback_success fallbackSuccessCount={}",
				fallbackMetrics.snapshot().fallbackSuccessCount()
		);
		return items;
	}
}
