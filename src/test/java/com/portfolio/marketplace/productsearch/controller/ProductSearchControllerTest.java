package com.portfolio.marketplace.productsearch.controller;

import com.portfolio.marketplace.productsearch.dto.response.ProductSearchResponse;
import com.portfolio.marketplace.productsearch.service.ProductSearchService;
import java.util.List;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.WebMvcTest;
import org.springframework.test.context.bean.override.mockito.MockitoBean;
import org.springframework.test.web.servlet.MockMvc;

import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

@WebMvcTest({ProductSearchController.class, ProductSearchBenchmarkController.class})
class ProductSearchControllerTest {

	@Autowired
	private MockMvc mockMvc;

	@MockitoBean
	private ProductSearchService productSearchService;

	@Test
	void searchReturnsApiResponseEnvelope() throws Exception {
		when(productSearchService.search(any()))
				.thenReturn(ProductSearchResponse.of(List.of(), 50, 100));

		mockMvc.perform(get("/api/v1/products/search")
						.param("categoryId", "35")
						.param("status", "ACTIVE")
						.param("color", "WHITE")
						.param("size", "L")
						.param("stockStatus", "OUT_OF_STOCK")
						.param("sort", "createdAtDesc")
						.param("limit", "50")
						.param("offset", "100"))
				.andExpect(status().isOk())
				.andExpect(jsonPath("$.data.items").isArray())
				.andExpect(jsonPath("$.data.page.limit").value(50))
				.andExpect(jsonPath("$.data.page.offset").value(100))
				.andExpect(jsonPath("$.data.page.returnedCount").value(0));
	}

	@Test
	void benchmarkDbTunedEndpointIsInternal() throws Exception {
		when(productSearchService.searchDbTuned(any()))
				.thenReturn(ProductSearchResponse.of(List.of(), 50, 100));

		mockMvc.perform(get("/internal/benchmarks/product-search/db-tuned")
						.param("categoryId", "75")
						.param("brandId", "943")
						.param("status", "ACTIVE")
						.param("minPrice", "10000")
						.param("maxPrice", "100000")
						.param("color", "BLACK")
						.param("size", "M")
						.param("stockStatus", "IN_STOCK")
						.param("sort", "reviewCountDesc")
						.param("limit", "50")
						.param("offset", "100"))
				.andExpect(status().isOk())
				.andExpect(jsonPath("$.data.items").isArray())
				.andExpect(jsonPath("$.data.page.limit").value(50))
				.andExpect(jsonPath("$.data.page.offset").value(100))
				.andExpect(jsonPath("$.data.page.returnedCount").value(0));
	}

	@Test
	void benchmarkDenormalizedDbEndpointIsInternal() throws Exception {
		when(productSearchService.searchDenormalizedDb(any()))
				.thenReturn(ProductSearchResponse.of(List.of(), 50, 100));

		mockMvc.perform(get("/internal/benchmarks/product-search/denormalized-db")
						.param("categoryId", "75")
						.param("brandId", "943")
						.param("status", "ACTIVE")
						.param("minPrice", "10000")
						.param("maxPrice", "100000")
						.param("color", "BLACK")
						.param("size", "M")
						.param("stockStatus", "IN_STOCK")
						.param("sort", "reviewCountDesc")
						.param("limit", "50")
						.param("offset", "100"))
				.andExpect(status().isOk())
				.andExpect(jsonPath("$.data.items").isArray())
				.andExpect(jsonPath("$.data.page.limit").value(50))
				.andExpect(jsonPath("$.data.page.offset").value(100))
				.andExpect(jsonPath("$.data.page.returnedCount").value(0));

		verify(productSearchService).searchDenormalizedDb(any());
	}

	@Test
	void benchmarkEndpointsAreNotExposedUnderProductApi() throws Exception {
		mockMvc.perform(get("/api/v1/products/search/db-tuned"))
				.andExpect(status().isNotFound());
		mockMvc.perform(get("/api/v1/products/search/denormalized-db"))
				.andExpect(status().isNotFound());
	}

	@Test
	void searchRejectsInvalidLimit() throws Exception {
		mockMvc.perform(get("/api/v1/products/search")
						.param("limit", "101"))
				.andExpect(status().isBadRequest());
	}

	@Test
	void searchRejectsNegativeOffset() throws Exception {
		mockMvc.perform(get("/api/v1/products/search")
						.param("offset", "-1"))
				.andExpect(status().isBadRequest());
	}

	@Test
	void searchRejectsUnsupportedSort() throws Exception {
		mockMvc.perform(get("/api/v1/products/search")
						.param("sort", "ratingDesc"))
				.andExpect(status().isBadRequest());
	}

	@Test
	void searchRejectsInvalidPriceRange() throws Exception {
		mockMvc.perform(get("/api/v1/products/search")
						.param("minPrice", "100000")
						.param("maxPrice", "10000"))
				.andExpect(status().isBadRequest());
	}
}
