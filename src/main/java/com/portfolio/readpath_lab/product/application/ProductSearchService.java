package com.portfolio.readpath_lab.product.application;

import com.portfolio.readpath_lab.product.api.ProductSearchRequest;
import com.portfolio.readpath_lab.product.api.ProductSearchResponse;
import com.portfolio.readpath_lab.product.repository.ProductSearchRepository;
import org.springframework.stereotype.Service;

@Service
public class ProductSearchService {

	private final ProductSearchRepository productSearchRepository;

	public ProductSearchService(ProductSearchRepository productSearchRepository) {
		this.productSearchRepository = productSearchRepository;
	}

	public ProductSearchResponse search(ProductSearchRequest request) {
		return ProductSearchResponse.of(
				productSearchRepository.search(request),
				request.getLimit(),
				request.getOffset()
		);
	}
}
