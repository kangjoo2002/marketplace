package com.portfolio.marketplace.productsearch.service;

import com.portfolio.marketplace.productsearch.domain.ProductSearchCondition;
import com.portfolio.marketplace.productsearch.dto.request.ProductSearchRequest;
import com.portfolio.marketplace.productsearch.dto.response.ProductSearchResponse;
import com.portfolio.marketplace.productsearch.repository.ProductSearchRepository;
import org.springframework.stereotype.Service;

@Service
public class ProductSearchService {

	private final ProductSearchReadPathRouter readPathRouter;
	private final ProductSearchRepository productSearchRepository;

	public ProductSearchService(
			ProductSearchReadPathRouter readPathRouter,
			ProductSearchRepository productSearchRepository
	) {
		this.readPathRouter = readPathRouter;
		this.productSearchRepository = productSearchRepository;
	}

	public ProductSearchResponse search(ProductSearchRequest request) {
		ProductSearchCondition condition = toCondition(request);
		return ProductSearchResponse.from(
				readPathRouter.search(condition),
				condition.getLimit(),
				condition.getOffset()
		);
	}

	public ProductSearchResponse searchDbTuned(ProductSearchRequest request) {
		ProductSearchCondition condition = toCondition(request);
		return ProductSearchResponse.from(
				productSearchRepository.searchDbTuned(condition),
				condition.getLimit(),
				condition.getOffset()
		);
	}

	public ProductSearchResponse searchDenormalizedDb(ProductSearchRequest request) {
		ProductSearchCondition condition = toCondition(request);
		return ProductSearchResponse.from(
				productSearchRepository.searchDenormalizedDb(condition),
				condition.getLimit(),
				condition.getOffset()
		);
	}

	private static ProductSearchCondition toCondition(ProductSearchRequest request) {
		return new ProductSearchCondition(
				request.getCategoryId(),
				request.getBrandId(),
				request.getStatus(),
				request.getMinPrice(),
				request.getMaxPrice(),
				request.getColor(),
				request.getSize(),
				request.getStockStatus(),
				request.getSort(),
				request.getLimit(),
				request.getOffset()
		);
	}
}
