package com.portfolio.marketplace.productsearch.infrastructure.opensearch;

import com.portfolio.marketplace.productsearch.domain.ProductSearchDocument;
import com.portfolio.marketplace.productsearch.domain.ProductSearchDocumentOption;
import java.math.BigDecimal;
import java.time.LocalDateTime;
import java.util.List;
import java.util.Map;
import org.junit.jupiter.api.Test;

import static org.assertj.core.api.Assertions.assertThat;

class OpenSearchProductSearchWriterTest {

	@Test
	void upsertsProductSearchDocumentToOpenSearchShape() {
		CapturingOpenSearchDocumentClient httpClient = new CapturingOpenSearchDocumentClient();
		OpenSearchProductSearchWriter writer = new OpenSearchProductSearchWriter(httpClient);
		ProductSearchDocument document = new ProductSearchDocument(
				1L,
				2L,
				3L,
				4L,
				"ACTIVE",
				10000,
				BigDecimal.valueOf(4.55),
				12,
				LocalDateTime.parse("2026-05-02T10:00:00"),
				LocalDateTime.parse("2026-05-02T10:01:00"),
				LocalDateTime.parse("2026-05-02T10:01:00"),
				LocalDateTime.parse("2026-05-02T10:02:00"),
				List.of(new ProductSearchDocumentOption("BLACK", "M", "IN_STOCK"))
		);

		writer.upsert(document);

		assertThat(httpClient.documentId).isEqualTo("1");
		assertThat(httpClient.document).containsEntry("productId", 1L);
		assertThat(httpClient.document).containsEntry("status", "ACTIVE");
		assertThat(httpClient.document).containsEntry("documentRefreshedAt", "2026-05-02T10:02");
		assertThat(httpClient.document.toString()).contains("stockStatus=IN_STOCK");
	}

	@Test
	void deletesByProductId() {
		CapturingOpenSearchDocumentClient httpClient = new CapturingOpenSearchDocumentClient();
		OpenSearchProductSearchWriter writer = new OpenSearchProductSearchWriter(httpClient);

		writer.deleteByProductId(10L);

		assertThat(httpClient.deletedDocumentId).isEqualTo("10");
	}

	private static class CapturingOpenSearchDocumentClient implements OpenSearchDocumentClient {

		private String documentId;
		private Map<String, Object> document;
		private String deletedDocumentId;

		@Override
		public void indexDocument(String documentId, Map<String, Object> document) {
			this.documentId = documentId;
			this.document = document;
		}

		@Override
		public void deleteDocument(String documentId) {
			this.deletedDocumentId = documentId;
		}
	}
}
