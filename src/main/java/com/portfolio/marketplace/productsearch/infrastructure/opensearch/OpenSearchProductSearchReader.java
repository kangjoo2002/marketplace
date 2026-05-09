package com.portfolio.marketplace.productsearch.infrastructure.opensearch;

import com.portfolio.marketplace.productsearch.domain.ProductSearchCondition;
import com.portfolio.marketplace.productsearch.domain.ProductSearchItem;
import com.portfolio.marketplace.productsearch.service.ProductSearchFallbackMetrics.OpenSearchFailureReason;
import com.portfolio.marketplace.productsearch.service.port.ProductSearchIndexReader;
import java.math.BigDecimal;
import java.time.LocalDateTime;
import java.time.OffsetDateTime;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import org.springframework.stereotype.Component;

@Component
public class OpenSearchProductSearchReader implements ProductSearchIndexReader {

	private final OpenSearchSearchClient openSearchSearchClient;

	public OpenSearchProductSearchReader(OpenSearchSearchClient openSearchSearchClient) {
		this.openSearchSearchClient = openSearchSearchClient;
	}

	@Override
	public List<ProductSearchItem> search(ProductSearchCondition condition) {
		Map<String, Object> response = openSearchSearchClient.search(buildQuery(condition));
		return parseResponse(response);
	}

	Map<String, Object> buildQuery(ProductSearchCondition condition) {
		List<Object> filters = new ArrayList<>();
		addTermFilter(filters, "categoryId", condition.getCategoryId());
		addTermFilter(filters, "brandId", condition.getBrandId());
		addTermFilter(filters, "status", condition.getStatus() == null ? null : condition.getStatus().name());
		addPriceRangeFilter(filters, condition);
		addNestedOptionFilter(filters, condition);

		Map<String, Object> query = new LinkedHashMap<>();
		query.put("from", condition.getOffset());
		query.put("size", condition.getLimit());
		query.put("_source", List.of(
				"productId",
				"sellerId",
				"categoryId",
				"brandId",
				"status",
				"price",
				"rating",
				"reviewCount",
				"createdAt",
				"updatedAt"
		));
		query.put("sort", sort(condition.getSort()));
		query.put("query", Map.of("bool", Map.of("filter", filters)));
		return query;
	}

	private static void addTermFilter(List<Object> filters, String field, Object value) {
		if (value == null) {
			return;
		}
		filters.add(Map.of("term", Map.of(field, value)));
	}

	private static void addPriceRangeFilter(List<Object> filters, ProductSearchCondition condition) {
		if (condition.getMinPrice() == null && condition.getMaxPrice() == null) {
			return;
		}

		Map<String, Object> priceRange = new LinkedHashMap<>();
		if (condition.getMinPrice() != null) {
			priceRange.put("gte", condition.getMinPrice());
		}
		if (condition.getMaxPrice() != null) {
			priceRange.put("lte", condition.getMaxPrice());
		}
		filters.add(Map.of("range", Map.of("price", priceRange)));
	}

	private static void addNestedOptionFilter(List<Object> filters, ProductSearchCondition condition) {
		List<Object> optionFilters = new ArrayList<>();
		addTermFilter(optionFilters, "options.color", condition.getColor() == null ? null : condition.getColor().name());
		addTermFilter(optionFilters, "options.size", condition.getSize() == null ? null : condition.getSize().name());
		addTermFilter(
				optionFilters,
				"options.stockStatus",
				condition.getStockStatus() == null ? null : condition.getStockStatus().name()
		);

		if (optionFilters.isEmpty()) {
			return;
		}

		filters.add(Map.of(
				"nested",
				Map.of(
						"path", "options",
						"query", Map.of("bool", Map.of("filter", optionFilters))
				)
		));
	}

	private static List<Object> sort(String sort) {
		return switch (sort) {
			case "reviewCountDesc" -> List.of(
					Map.of("reviewCount", Map.of("order", "desc")),
					Map.of("productId", Map.of("order", "desc"))
			);
			case "priceAsc" -> List.of(
					Map.of("price", Map.of("order", "asc")),
					Map.of("productId", Map.of("order", "asc"))
			);
			case "priceDesc" -> List.of(
					Map.of("price", Map.of("order", "desc")),
					Map.of("productId", Map.of("order", "desc"))
			);
			case "createdAtDesc" -> List.of(
					Map.of("createdAt", Map.of("order", "desc")),
					Map.of("productId", Map.of("order", "desc"))
			);
			default -> throw new IllegalArgumentException("Unsupported sort: " + sort);
		};
	}

	@SuppressWarnings("unchecked")
	private static List<ProductSearchItem> parseResponse(Map<String, Object> response) {
		Object hitsObject = response.get("hits");
		if (!(hitsObject instanceof Map<?, ?> hits)) {
			throw malformed("OpenSearch response did not contain hits");
		}

		Object hitListObject = hits.get("hits");
		if (!(hitListObject instanceof List<?> hitList)) {
			throw malformed("OpenSearch response hits.hits was not an array");
		}

		List<ProductSearchItem> items = new ArrayList<>();
		for (Object hitObject : hitList) {
			if (!(hitObject instanceof Map<?, ?> hit)) {
				throw malformed("OpenSearch hit was not an object");
			}
			Object sourceObject = hit.get("_source");
			if (!(sourceObject instanceof Map<?, ?> source)) {
				throw malformed("OpenSearch hit did not contain _source");
			}
			items.add(toItem((Map<String, Object>) source));
		}
		return items;
	}

	private static ProductSearchItem toItem(Map<String, Object> source) {
		return new ProductSearchItem(
				longValue(source, "productId"),
				longValue(source, "sellerId"),
				longValue(source, "categoryId"),
				longValue(source, "brandId"),
				stringValue(source, "status"),
				intValue(source, "price"),
				bigDecimalValue(source, "rating"),
				intValue(source, "reviewCount"),
				dateTimeValue(source, "createdAt"),
				dateTimeValue(source, "updatedAt")
		);
	}

	private static Long longValue(Map<String, Object> source, String field) {
		Object value = required(source, field);
		if (value instanceof Number number) {
			return number.longValue();
		}
		return Long.valueOf(value.toString());
	}

	private static Integer intValue(Map<String, Object> source, String field) {
		Object value = required(source, field);
		if (value instanceof Number number) {
			return number.intValue();
		}
		return Integer.valueOf(value.toString());
	}

	private static String stringValue(Map<String, Object> source, String field) {
		return required(source, field).toString();
	}

	private static BigDecimal bigDecimalValue(Map<String, Object> source, String field) {
		Object value = required(source, field);
		if (value instanceof BigDecimal bigDecimal) {
			return bigDecimal;
		}
		return new BigDecimal(value.toString());
	}

	private static LocalDateTime dateTimeValue(Map<String, Object> source, String field) {
		String value = required(source, field).toString();
		if (value.endsWith("Z") || value.matches(".*[+-][0-9]{2}:[0-9]{2}$")) {
			return OffsetDateTime.parse(value).toLocalDateTime();
		}
		return LocalDateTime.parse(value);
	}

	private static Object required(Map<String, Object> source, String field) {
		Object value = source.get(field);
		if (value == null) {
			throw malformed("OpenSearch _source missing required field: " + field);
		}
		return value;
	}

	private static OpenSearchProductSearchException malformed(String message) {
		return new OpenSearchProductSearchException(OpenSearchFailureReason.MALFORMED_RESPONSE, message);
	}
}
