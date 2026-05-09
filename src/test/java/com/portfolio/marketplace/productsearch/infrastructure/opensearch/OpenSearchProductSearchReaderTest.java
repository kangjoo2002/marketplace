package com.portfolio.marketplace.productsearch.infrastructure.opensearch;

import com.portfolio.marketplace.product.domain.ProductColor;
import com.portfolio.marketplace.product.domain.ProductSize;
import com.portfolio.marketplace.product.domain.ProductStatus;
import com.portfolio.marketplace.product.domain.StockStatus;
import com.portfolio.marketplace.productsearch.domain.ProductSearchCondition;
import com.portfolio.marketplace.productsearch.domain.ProductSearchItem;
import java.util.List;
import java.util.Map;
import org.junit.jupiter.api.Test;

import static org.assertj.core.api.Assertions.assertThat;

class OpenSearchProductSearchReaderTest {

	@Test
	void buildsNestedOptionQueryForSameOptionRowSemantics() {
		CapturingOpenSearchHttpClient httpClient = new CapturingOpenSearchHttpClient(Map.of(
				"hits", Map.of("hits", List.of())
		));
		OpenSearchProductSearchReader reader = new OpenSearchProductSearchReader(httpClient);
		ProductSearchCondition condition = new ProductSearchCondition();
		condition.setCategoryId(75L);
		condition.setBrandId(943L);
		condition.setStatus(ProductStatus.ACTIVE);
		condition.setMinPrice(10000);
		condition.setMaxPrice(100000);
		condition.setColor(ProductColor.BLACK);
		condition.setSize(ProductSize.M);
		condition.setStockStatus(StockStatus.IN_STOCK);
		condition.setSort("reviewCountDesc");
		condition.setLimit(50);
		condition.setOffset(100);

		reader.search(condition);

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
	void mapsOpenSearchSourceToProductSearchItem() {
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
		OpenSearchProductSearchReader reader = new OpenSearchProductSearchReader(httpClient);

		List<ProductSearchItem> items = reader.search(new ProductSearchCondition());

		assertThat(items).hasSize(1);
		ProductSearchItem item = items.get(0);
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
