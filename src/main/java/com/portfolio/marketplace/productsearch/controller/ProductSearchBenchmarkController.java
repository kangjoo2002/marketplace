package com.portfolio.marketplace.productsearch.controller;

import com.portfolio.marketplace.global.response.ApiResponse;
import com.portfolio.marketplace.productsearch.dto.request.ProductSearchRequest;
import com.portfolio.marketplace.productsearch.dto.response.ProductSearchResponse;
import com.portfolio.marketplace.productsearch.service.ProductSearchService;
import jakarta.validation.Valid;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.ModelAttribute;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

@RestController
@RequestMapping("/internal/benchmarks/product-search")
public class ProductSearchBenchmarkController {

	private final ProductSearchService productSearchService;

	public ProductSearchBenchmarkController(ProductSearchService productSearchService) {
		this.productSearchService = productSearchService;
	}

	@GetMapping("/db-tuned")
	public ApiResponse<ProductSearchResponse> searchDbTuned(@Valid @ModelAttribute ProductSearchRequest request) {
		return ApiResponse.of(productSearchService.searchDbTuned(request));
	}

	@GetMapping("/denormalized-db")
	public ApiResponse<ProductSearchResponse> searchDenormalizedDb(@Valid @ModelAttribute ProductSearchRequest request) {
		return ApiResponse.of(productSearchService.searchDenormalizedDb(request));
	}
}
