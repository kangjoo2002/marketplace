package com.portfolio.readpath_lab.product.opensearch;

import com.portfolio.readpath_lab.product.api.ProductSearchItemResponse;
import com.portfolio.readpath_lab.product.api.ProductSearchRequest;
import com.portfolio.readpath_lab.product.domain.ProductColor;
import com.portfolio.readpath_lab.product.domain.ProductSize;
import com.portfolio.readpath_lab.product.domain.ProductStatus;
import com.portfolio.readpath_lab.product.domain.StockStatus;
import java.util.List;
import java.util.Map;
import org.junit.jupiter.api.Test;

import static org.assertj.core.api.Assertions.assertThat;

class OpenSearchProductSearchAdapterTest {

	@Test
	void buildsNestedOptionQueryForSameOptionRowSemantics() {
		CapturingOpenSearchHttpClient httpClient = new CapturingOpenSearchHttpClient(Map.of(
				"hits", Map.of("hits", List.of())
		));
		OpenSearchProductSearchAdapter adapter = new OpenSearchProductSearchAdapter(httpClient);
		ProductSearchRequest request = new ProductSearchRequest();
		request.setCategoryId(75L);
		request.setBrandId(943L);
		request.setStatus(ProductStatus.ACTIVE);
		request.setMinPrice(10000);
		request.setMaxPrice(100000);
		request.setColor(ProductColor.BLACK);
		request.setSize(ProductSize.M);
		request.setStockStatus(StockStatus.IN_STOCK);
		request.setSort("reviewCountDesc");
		request.setLimit(50);
		request.setOffset(100);

		adapter.search(request);

		assertThat(httpClient.query).containsEntry("from", 100);
		assertThat(httpClient.query).containsEntry("size", 50);
		assertThat(httpClient.query.toString()).contains("nested");
		assertThat(httpClient.query.toString()).contains("path=options");
		assertThat(httpClient.query.toString()).contains("options.color");
		assertThat(httpClient.query.toString()).contains("options.size");
		assertThat(httpClient.query.toString()).contains("options.stockStatus");
		assertThat(httpClient.query.toString()).contains("reviewCount");
		assertThat(httpClient.query.toString()).contains("productId");
	}

	@Test
	void mapsOpenSearchSourceToApiItemShape() {
		CapturingOpenSearchHttpClient httpClient = new CapturingOpenSearchHttpClient(Map.of(
				"hits", Map.of(
						"hits", List.of(Map.of(
								"_source", Map.of(
										"productId", 1,
										"sellerId", 2,
										"categoryId", 3,
										"brandId", 4,
										"status", "ACTIVE",
										"price", 10000,
										"rating", 4.55,
										"reviewCount", 12,
										"createdAt", "2026-05-02T10:00:00",
										"updatedAt", "2026-05-02T10:01:00"
								)
						))
				)
		));
		OpenSearchProductSearchAdapter adapter = new OpenSearchProductSearchAdapter(httpClient);

		List<ProductSearchItemResponse> items = adapter.search(new ProductSearchRequest());

		assertThat(items).hasSize(1);
		ProductSearchItemResponse item = items.get(0);
		assertThat(item.id()).isEqualTo(1L);
		assertThat(item.sellerId()).isEqualTo(2L);
		assertThat(item.status()).isEqualTo("ACTIVE");
		assertThat(item.price()).isEqualTo(10000);
		assertThat(item.reviewCount()).isEqualTo(12);
	}

	private static class CapturingOpenSearchHttpClient implements OpenSearchHttpClient {

		private final Map<String, Object> response;
		private Map<String, Object> query;

		private CapturingOpenSearchHttpClient(Map<String, Object> response) {
			this.response = response;
		}

		@Override
		public Map<String, Object> search(Map<String, Object> query) {
			this.query = query;
			return response;
		}
	}
}
