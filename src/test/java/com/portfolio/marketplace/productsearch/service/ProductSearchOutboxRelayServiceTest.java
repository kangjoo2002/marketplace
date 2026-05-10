package com.portfolio.marketplace.productsearch.service;

import com.portfolio.marketplace.productsearch.config.ProductSearchIndexingProperties;
import com.portfolio.marketplace.productsearch.domain.ProductSearchDocument;
import com.portfolio.marketplace.productsearch.domain.SearchOutboxEvent;
import com.portfolio.marketplace.productsearch.repository.ProductSearchDocumentRepository;
import com.portfolio.marketplace.productsearch.repository.SearchOutboxStore;
import com.portfolio.marketplace.productsearch.service.port.ProductSearchIndexWriter;
import java.math.BigDecimal;
import java.time.Clock;
import java.time.Instant;
import java.time.LocalDateTime;
import java.time.OffsetDateTime;
import java.time.ZoneOffset;
import java.util.List;
import java.util.Optional;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.springframework.boot.test.system.CapturedOutput;
import org.springframework.boot.test.system.OutputCaptureExtension;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.contains;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

@ExtendWith(OutputCaptureExtension.class)
class ProductSearchOutboxRelayServiceTest {

	private static final String CLAIM_TOKEN = "00000000-0000-0000-0000-000000000001";

	private final SearchOutboxStore outboxStore = mock(SearchOutboxStore.class);
	private final ProductSearchDocumentRepository documentRepository = mock(ProductSearchDocumentRepository.class);
	private final ProductSearchIndexWriter indexWriter = mock(ProductSearchIndexWriter.class);
	private final ProductSearchIndexingProperties properties = new ProductSearchIndexingProperties();
	private final Clock clock = Clock.fixed(Instant.parse("2026-05-02T10:02:00Z"), ZoneOffset.UTC);
	private final ProductSearchOutboxRelayService relayService = new ProductSearchOutboxRelayService(
			outboxStore,
			documentRepository,
			indexWriter,
			properties,
			clock
	);

	@Test
	void upsertsSourceDocumentAndMarksDone(CapturedOutput output) {
		SearchOutboxEvent event = event(1L, "PRODUCT_UPDATED", 0);
		when(outboxStore.claimPendingProductEvents(20, 60000L)).thenReturn(List.of(event));
		when(documentRepository.findByProductId(10L)).thenReturn(Optional.of(activeDocument()));

		relayService.processBatch();

		verify(indexWriter).upsert(activeDocument().refreshedAt(LocalDateTime.parse("2026-05-02T10:02:00")));
		verify(outboxStore).markDone(event);
		verify(outboxStore, never()).markFailed(any(SearchOutboxEvent.class), any());
		assertThat(output.getOut())
				.contains("product_search_outbox_indexing_latency")
				.contains("eventId=1")
				.contains("resultStatus=DONE")
				.contains("queueWaitMs=5000")
				.contains("sourceDocumentLoadMs=")
				.contains("openSearchWriteMs=")
				.contains("outboxStateTransitionMs=")
				.contains("relayProcessingMs=");
	}

	@Test
	void deletesDocumentForProductDeletedEvent() {
		SearchOutboxEvent event = event(2L, "PRODUCT_DELETED", 0);
		when(outboxStore.claimPendingProductEvents(20, 60000L)).thenReturn(List.of(event));

		relayService.processBatch();

		verify(indexWriter).deleteByProductId(10L);
		verify(documentRepository, never()).findByProductId(10L);
		verify(outboxStore).markDone(event);
	}

	@Test
	void deletesDocumentWhenSourceStatusIsDeleted() {
		SearchOutboxEvent event = event(3L, "PRODUCT_STATUS_CHANGED", 0);
		when(outboxStore.claimPendingProductEvents(20, 60000L)).thenReturn(List.of(event));
		when(documentRepository.findByProductId(10L)).thenReturn(Optional.of(deletedDocument()));

		relayService.processBatch();

		verify(indexWriter).deleteByProductId(10L);
		verify(indexWriter, never()).upsert(any());
		verify(outboxStore).markDone(event);
	}

	@Test
	void schedulesRetryWhenIndexWriteFailsBeforeMaxRetry() {
		SearchOutboxEvent event = event(4L, "PRODUCT_UPDATED", 0);
		when(outboxStore.claimPendingProductEvents(20, 60000L)).thenReturn(List.of(event));
		when(documentRepository.findByProductId(10L)).thenReturn(Optional.of(activeDocument()));
		org.mockito.Mockito.doThrow(new IllegalStateException("OpenSearch down"))
				.when(indexWriter)
				.upsert(any());

		relayService.processBatch();

		verify(outboxStore).markPendingRetry(
				eq(event),
				contains("OpenSearch down"),
				eq(LocalDateTime.parse("2026-05-02T10:02:10"))
		);
		verify(outboxStore, never()).markDone(event);
		verify(outboxStore, never()).markFailed(any(SearchOutboxEvent.class), any());
	}

	@Test
	void marksFailedWhenIndexWriteFailsAtMaxRetry() {
		SearchOutboxEvent event = event(5L, "PRODUCT_UPDATED", 2);
		when(outboxStore.claimPendingProductEvents(20, 60000L)).thenReturn(List.of(event));
		when(documentRepository.findByProductId(10L)).thenReturn(Optional.of(activeDocument()));
		org.mockito.Mockito.doThrow(new IllegalStateException("OpenSearch down"))
				.when(indexWriter)
				.upsert(any());

		relayService.processBatch();

		verify(outboxStore).markFailed(eq(event), contains("OpenSearch down"));
		verify(outboxStore, never()).markPendingRetry(any(SearchOutboxEvent.class), any(), any());
		verify(outboxStore, never()).markDone(event);
	}

	private static SearchOutboxEvent event(long id, String eventType, int retryCount) {
		return new SearchOutboxEvent(
				id,
				10L,
				eventType,
				1,
				"{}",
				retryCount,
				CLAIM_TOKEN,
				OffsetDateTime.parse("2026-05-02T10:00:00Z"),
				OffsetDateTime.parse("2026-05-02T10:00:05Z")
		);
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
