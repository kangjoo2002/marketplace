package com.portfolio.readpath_lab.product.opensearch;

import com.portfolio.readpath_lab.product.api.ProductSearchItemResponse;
import com.portfolio.readpath_lab.product.api.ProductSearchRequest;
import com.portfolio.readpath_lab.product.application.ProductSearchFallbackMetrics.OpenSearchFailureReason;
import java.math.BigDecimal;
import java.time.LocalDateTime;
import java.time.OffsetDateTime;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import org.springframework.stereotype.Component;

@Component
public class OpenSearchProductSearchAdapter {

	private final OpenSearchHttpClient openSearchHttpClient;

	public OpenSearchProductSearchAdapter(OpenSearchHttpClient openSearchHttpClient) {
		this.openSearchHttpClient = openSearchHttpClient;
	}

	public List<ProductSearchItemResponse> search(ProductSearchRequest request) {
		Map<String, Object> response = openSearchHttpClient.search(buildQuery(request));
		return parseResponse(response);
	}

	Map<String, Object> buildQuery(ProductSearchRequest request) {
		List<Object> filters = new ArrayList<>();
		addTermFilter(filters, "categoryId", request.getCategoryId());
		addTermFilter(filters, "brandId", request.getBrandId());
		addTermFilter(filters, "status", request.getStatus() == null ? null : request.getStatus().name());
		addPriceRangeFilter(filters, request);
		addNestedOptionFilter(filters, request);

		Map<String, Object> query = new LinkedHashMap<>();
		query.put("from", request.getOffset());
		query.put("size", request.getLimit());
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
		query.put("sort", sort(request.getSort()));
		query.put("query", Map.of("bool", Map.of("filter", filters)));
		return query;
	}

	private static void addTermFilter(List<Object> filters, String field, Object value) {
		if (value == null) {
			return;
		}
		filters.add(Map.of("term", Map.of(field, value)));
	}

	private static void addPriceRangeFilter(List<Object> filters, ProductSearchRequest request) {
		if (request.getMinPrice() == null && request.getMaxPrice() == null) {
			return;
		}

		Map<String, Object> priceRange = new LinkedHashMap<>();
		if (request.getMinPrice() != null) {
			priceRange.put("gte", request.getMinPrice());
		}
		if (request.getMaxPrice() != null) {
			priceRange.put("lte", request.getMaxPrice());
		}
		filters.add(Map.of("range", Map.of("price", priceRange)));
	}

	private static void addNestedOptionFilter(List<Object> filters, ProductSearchRequest request) {
		List<Object> optionFilters = new ArrayList<>();
		addTermFilter(optionFilters, "options.color", request.getColor() == null ? null : request.getColor().name());
		addTermFilter(optionFilters, "options.size", request.getSize() == null ? null : request.getSize().name());
		addTermFilter(
				optionFilters,
				"options.stockStatus",
				request.getStockStatus() == null ? null : request.getStockStatus().name()
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
	private static List<ProductSearchItemResponse> parseResponse(Map<String, Object> response) {
		Object hitsObject = response.get("hits");
		if (!(hitsObject instanceof Map<?, ?> hits)) {
			throw malformed("OpenSearch response did not contain hits");
		}

		Object hitListObject = hits.get("hits");
		if (!(hitListObject instanceof List<?> hitList)) {
			throw malformed("OpenSearch response hits.hits was not an array");
		}

		List<ProductSearchItemResponse> items = new ArrayList<>();
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

	private static ProductSearchItemResponse toItem(Map<String, Object> source) {
		return new ProductSearchItemResponse(
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
