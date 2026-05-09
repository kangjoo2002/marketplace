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
@RequestMapping("/api/v1/products")
public class ProductSearchController {

	private final ProductSearchService productSearchService;

	public ProductSearchController(ProductSearchService productSearchService) {
		this.productSearchService = productSearchService;
	}

	@GetMapping("/search")
	public ApiResponse<ProductSearchResponse> search(@Valid @ModelAttribute ProductSearchRequest request) {
		return ApiResponse.of(productSearchService.search(request));
	}
}
