package com.portfolio.marketplace.productsearch.service;

import com.portfolio.marketplace.productsearch.config.ProductSearchIndexingProperties;
import com.portfolio.marketplace.productsearch.domain.ProductSearchDocument;
import com.portfolio.marketplace.productsearch.domain.SearchOutboxEvent;
import com.portfolio.marketplace.productsearch.repository.ProductSearchDocumentRepository;
import com.portfolio.marketplace.productsearch.repository.SearchOutboxRepository;
import com.portfolio.marketplace.productsearch.service.port.ProductSearchIndexWriter;
import java.math.BigDecimal;
import java.time.Clock;
import java.time.Instant;
import java.time.LocalDateTime;
import java.time.ZoneOffset;
import java.util.List;
import java.util.Optional;
import org.junit.jupiter.api.Test;

import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyLong;
import static org.mockito.ArgumentMatchers.contains;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

class ProductSearchOutboxRelayServiceTest {

	private final SearchOutboxRepository outboxRepository = mock(SearchOutboxRepository.class);
	private final ProductSearchDocumentRepository documentRepository = mock(ProductSearchDocumentRepository.class);
	private final ProductSearchIndexWriter indexWriter = mock(ProductSearchIndexWriter.class);
	private final ProductSearchIndexingProperties properties = new ProductSearchIndexingProperties();
	private final Clock clock = Clock.fixed(Instant.parse("2026-05-02T10:02:00Z"), ZoneOffset.UTC);
	private final ProductSearchOutboxRelayService relayService = new ProductSearchOutboxRelayService(
			outboxRepository,
			documentRepository,
			indexWriter,
			properties,
			clock
	);

	@Test
	void upsertsSourceDocumentAndMarksDone() {
		SearchOutboxEvent event = new SearchOutboxEvent(1L, 10L, "PRODUCT_UPDATED", 1, "{}", 0);
		when(outboxRepository.claimPendingProductEvents(20)).thenReturn(List.of(event));
		when(documentRepository.findByProductId(10L)).thenReturn(Optional.of(activeDocument()));

		relayService.processBatch();

		verify(indexWriter).upsert(activeDocument().refreshedAt(LocalDateTime.parse("2026-05-02T10:02:00")));
		verify(outboxRepository).markDone(1L);
		verify(outboxRepository, never()).markFailed(anyLong(), any());
	}

	@Test
	void deletesDocumentForProductDeletedEvent() {
		SearchOutboxEvent event = new SearchOutboxEvent(2L, 10L, "PRODUCT_DELETED", 1, "{}", 0);
		when(outboxRepository.claimPendingProductEvents(20)).thenReturn(List.of(event));

		relayService.processBatch();

		verify(indexWriter).deleteByProductId(10L);
		verify(documentRepository, never()).findByProductId(10L);
		verify(outboxRepository).markDone(2L);
	}

	@Test
	void deletesDocumentWhenSourceStatusIsDeleted() {
		SearchOutboxEvent event = new SearchOutboxEvent(3L, 10L, "PRODUCT_STATUS_CHANGED", 1, "{}", 0);
		when(outboxRepository.claimPendingProductEvents(20)).thenReturn(List.of(event));
		when(documentRepository.findByProductId(10L)).thenReturn(Optional.of(deletedDocument()));

		relayService.processBatch();

		verify(indexWriter).deleteByProductId(10L);
		verify(indexWriter, never()).upsert(any());
		verify(outboxRepository).markDone(3L);
	}

	@Test
	void schedulesRetryWhenIndexWriteFailsBeforeMaxRetry() {
		SearchOutboxEvent event = new SearchOutboxEvent(4L, 10L, "PRODUCT_UPDATED", 1, "{}", 0);
		when(outboxRepository.claimPendingProductEvents(20)).thenReturn(List.of(event));
		when(documentRepository.findByProductId(10L)).thenReturn(Optional.of(activeDocument()));
		org.mockito.Mockito.doThrow(new IllegalStateException("OpenSearch down"))
				.when(indexWriter)
				.upsert(any());

		relayService.processBatch();

		verify(outboxRepository).markPendingRetry(
				eq(4L),
				contains("OpenSearch down"),
				eq(LocalDateTime.parse("2026-05-02T10:02:10"))
		);
		verify(outboxRepository, never()).markDone(4L);
		verify(outboxRepository, never()).markFailed(anyLong(), any());
	}

	@Test
	void marksFailedWhenIndexWriteFailsAtMaxRetry() {
		SearchOutboxEvent event = new SearchOutboxEvent(5L, 10L, "PRODUCT_UPDATED", 1, "{}", 2);
		when(outboxRepository.claimPendingProductEvents(20)).thenReturn(List.of(event));
		when(documentRepository.findByProductId(10L)).thenReturn(Optional.of(activeDocument()));
		org.mockito.Mockito.doThrow(new IllegalStateException("OpenSearch down"))
				.when(indexWriter)
				.upsert(any());

		relayService.processBatch();

		verify(outboxRepository).markFailed(eq(5L), contains("OpenSearch down"));
		verify(outboxRepository, never()).markPendingRetry(anyLong(), any(), any());
		verify(outboxRepository, never()).markDone(5L);
	}

	private static ProductSearchDocument activeDocument() {
		return document("ACTIVE");
	}

	private static ProductSearchDocument deletedDocument() {
		return document("DELETED");
	}

	private static ProductSearchDocument document(String status) {
		return new ProductSearchDocument(
				10L,
				20L,
				30L,
				40L,
				status,
				10000,
				BigDecimal.valueOf(4.55),
				12,
				LocalDateTime.parse("2026-05-02T10:00:00"),
				LocalDateTime.parse("2026-05-02T10:01:00"),
				LocalDateTime.parse("2026-05-02T10:01:00"),
				null,
				List.of()
		);
	}
}
