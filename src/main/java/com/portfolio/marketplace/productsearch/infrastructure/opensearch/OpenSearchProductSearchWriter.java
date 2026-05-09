package com.portfolio.marketplace.productsearch.infrastructure.opensearch;

import com.portfolio.marketplace.productsearch.domain.ProductSearchDocument;
import com.portfolio.marketplace.productsearch.domain.ProductSearchDocumentOption;
import com.portfolio.marketplace.productsearch.service.port.ProductSearchIndexWriter;
import java.time.LocalDateTime;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import org.springframework.stereotype.Component;

@Component
public class OpenSearchProductSearchWriter implements ProductSearchIndexWriter {

	private final OpenSearchDocumentClient documentClient;

	public OpenSearchProductSearchWriter(OpenSearchDocumentClient documentClient) {
		this.documentClient = documentClient;
	}

	@Override
	public void upsert(ProductSearchDocument document) {
		documentClient.indexDocument(Long.toString(document.productId()), toSource(document));
	}

	@Override
	public void deleteByProductId(long productId) {
		documentClient.deleteDocument(Long.toString(productId));
	}

	private static Map<String, Object> toSource(ProductSearchDocument document) {
		Map<String, Object> source = new LinkedHashMap<>();
		source.put("productId", document.productId());
		source.put("sellerId", document.sellerId());
		source.put("categoryId", document.categoryId());
		source.put("brandId", document.brandId());
		source.put("status", document.status());
		source.put("price", document.price());
		source.put("rating", document.rating());
		source.put("reviewCount", document.reviewCount());
		source.put("createdAt", toIsoString(document.createdAt()));
		source.put("updatedAt", toIsoString(document.updatedAt()));
		source.put("sourceUpdatedAt", toIsoString(document.sourceUpdatedAt()));
		source.put("documentRefreshedAt", toIsoString(document.documentRefreshedAt()));
		source.put("options", toOptionSources(document.options()));
		return source;
	}

	private static List<Map<String, Object>> toOptionSources(List<ProductSearchDocumentOption> options) {
		return options.stream()
				.map(option -> {
					Map<String, Object> source = new LinkedHashMap<>();
					source.put("color", option.color());
					source.put("size", option.size());
					source.put("stockStatus", option.stockStatus());
					return source;
				})
				.toList();
	}

	private static String toIsoString(LocalDateTime value) {
		return value == null ? null : value.toString();
	}
}
