package com.portfolio.readpath_lab.product.api;

import com.portfolio.readpath_lab.product.application.ProductSearchService;
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
	public ProductSearchResponse search(@Valid @ModelAttribute ProductSearchRequest request) {
		return productSearchService.search(request);
	}

	@GetMapping("/search/db-tuned")
	public ProductSearchResponse searchDbTuned(@Valid @ModelAttribute ProductSearchRequest request) {
		return productSearchService.searchDbTuned(request);
	}
}
