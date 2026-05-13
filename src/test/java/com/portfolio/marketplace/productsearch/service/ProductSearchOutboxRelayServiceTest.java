package com.portfolio.marketplace.productsearch.service;

import com.portfolio.marketplace.productsearch.config.ProductSearchIndexingProperties;
import com.portfolio.marketplace.productsearch.domain.ProductSearchDocument;
import com.portfolio.marketplace.productsearch.domain.SearchOutboxEvent;
import com.portfolio.marketplace.productsearch.repository.ProductSearchDocumentRepository;
import com.portfolio.marketplace.productsearch.repository.SearchOutboxStore;
import com.portfolio.marketplace.productsearch.service.port.ProductSearchIndexWriter;
import io.micrometer.core.instrument.simple.SimpleMeterRegistry;
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
import static org.mockito.Mockito.doThrow;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.times;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

@ExtendWith(OutputCaptureExtension.class)
class ProductSearchOutboxRelayServiceTest {

	private static final String CLAIM_TOKEN = "00000000-0000-0000-0000-000000000001";

	private final SearchOutboxStore outboxStore = mock(SearchOutboxStore.class);
	private final ProductSearchDocumentRepository documentRepository = mock(ProductSearchDocumentRepository.class);
	private final ProductSearchIndexWriter indexWriter = mock(ProductSearchIndexWriter.class);
	private final ProductSearchIndexingProperties properties = new ProductSearchIndexingProperties();
	private final SimpleMeterRegistry meterRegistry = new SimpleMeterRegistry();
	private final Clock clock = Clock.fixed(Instant.parse("2026-05-02T10:02:00Z"), ZoneOffset.UTC);
	private final ProductSearchOutboxRelayService relayService = new ProductSearchOutboxRelayService(
			outboxStore,
			documentRepository,
			indexWriter,
			properties,
			clock,
			meterRegistry
	);

	@Test
	void upsertsSourceDocumentAndMarksDone(CapturedOutput output) {
		SearchOutboxEvent event = event(1L, "PRODUCT_UPDATED", 0);
		when(outboxStore.claimPendingProductEvents(20, 60000L, "local-relay")).thenReturn(List.of(event));
		when(documentRepository.findByProductId(10L)).thenReturn(Optional.of(activeDocument()));

		relayService.processBatch();

		verify(indexWriter).upsert(activeDocument().refreshedAt(LocalDateTime.parse("2026-05-02T10:02:00")));
		verify(outboxStore).markDone(event);
		verify(outboxStore, never()).markFailed(any(SearchOutboxEvent.class), any());
		assertTimingMetricsRecorded("done", 1L);
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
	void deletesDocumentWhenLatestProductIsMissing() {
		SearchOutboxEvent event = event(2L, "PRODUCT_DELETED", 0);
		when(outboxStore.claimPendingProductEvents(20, 60000L, "local-relay")).thenReturn(List.of(event));
		when(documentRepository.findByProductId(10L)).thenReturn(Optional.empty());

		relayService.processBatch();

		verify(documentRepository).findByProductId(10L);
		verify(indexWriter).deleteByProductId(10L);
		verify(outboxStore).markDone(event);
		assertThat(timerCount("product_search_outbox_relay_opensearch_write", "done")).isEqualTo(1L);
	}

	@Test
	void deletesDocumentWhenSourceStatusIsDeleted() {
		SearchOutboxEvent event = event(3L, "PRODUCT_STATUS_CHANGED", 0);
		when(outboxStore.claimPendingProductEvents(20, 60000L, "local-relay")).thenReturn(List.of(event));
		when(documentRepository.findByProductId(10L)).thenReturn(Optional.of(deletedDocument()));

		relayService.processBatch();

		verify(indexWriter).deleteByProductId(10L);
		verify(indexWriter, never()).upsert(any());
		verify(outboxStore).markDone(event);
	}

	@Test
	void schedulesRetryWhenIndexWriteFailsBeforeMaxRetry() {
		SearchOutboxEvent event = event(4L, "PRODUCT_UPDATED", 0);
		when(outboxStore.claimPendingProductEvents(20, 60000L, "local-relay")).thenReturn(List.of(event));
		when(documentRepository.findByProductId(10L)).thenReturn(Optional.of(activeDocument()));
		doThrow(new IllegalStateException("OpenSearch down"))
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
		assertTimingMetricsRecorded("pending_retry", 1L);
	}

	@Test
	void marksFailedWhenIndexWriteFailsAtMaxRetry() {
		SearchOutboxEvent event = event(5L, "PRODUCT_UPDATED", 2);
		when(outboxStore.claimPendingProductEvents(20, 60000L, "local-relay")).thenReturn(List.of(event));
		when(documentRepository.findByProductId(10L)).thenReturn(Optional.of(activeDocument()));
		doThrow(new IllegalStateException("OpenSearch down"))
				.when(indexWriter)
				.upsert(any());

		relayService.processBatch();

		verify(outboxStore).markFailed(eq(event), contains("OpenSearch down"));
		verify(outboxStore, never()).markPendingRetry(any(SearchOutboxEvent.class), any(), any());
		verify(outboxStore, never()).markDone(event);
		assertTimingMetricsRecorded("failed", 1L);
	}

	@Test
	void repeatedSameProductIdPreviouslyCausedRepeatedLoadsAndWritesButNowProcessesOnce() {
		SearchOutboxEvent firstEvent = event(10L, 10L, "PRODUCT_UPDATED", 0);
		SearchOutboxEvent secondEvent = event(11L, 10L, "PRODUCT_STATUS_CHANGED", 0);
		SearchOutboxEvent thirdEvent = event(12L, 10L, "PRODUCT_UPDATED", 0);
		when(outboxStore.claimPendingProductEvents(20, 60000L, "local-relay"))
				.thenReturn(List.of(firstEvent, secondEvent, thirdEvent));
		when(documentRepository.findByProductId(10L)).thenReturn(Optional.of(activeDocument()));

		int processedCount = relayService.processBatch();

		assertThat(processedCount).isEqualTo(3);
		verify(documentRepository, times(1)).findByProductId(10L);
		verify(indexWriter, times(1)).upsert(activeDocument().refreshedAt(LocalDateTime.parse("2026-05-02T10:02:00")));
		verify(outboxStore).markDone(firstEvent);
		verify(outboxStore).markDone(secondEvent);
		verify(outboxStore).markDone(thirdEvent);
		assertTimingMetricsRecorded("done", 1L);
	}

	@Test
	void differentProductIdsProcessSeparately() {
		SearchOutboxEvent firstEvent = event(20L, 1L, "PRODUCT_UPDATED", 0);
		SearchOutboxEvent secondEvent = event(21L, 2L, "PRODUCT_UPDATED", 0);
		SearchOutboxEvent thirdEvent = event(22L, 3L, "PRODUCT_UPDATED", 0);
		when(outboxStore.claimPendingProductEvents(20, 60000L, "local-relay"))
				.thenReturn(List.of(firstEvent, secondEvent, thirdEvent));
		when(documentRepository.findByProductId(1L)).thenReturn(Optional.of(activeDocument(1L)));
		when(documentRepository.findByProductId(2L)).thenReturn(Optional.of(activeDocument(2L)));
		when(documentRepository.findByProductId(3L)).thenReturn(Optional.of(activeDocument(3L)));

		relayService.processBatch();

		verify(documentRepository, times(1)).findByProductId(1L);
		verify(documentRepository, times(1)).findByProductId(2L);
		verify(documentRepository, times(1)).findByProductId(3L);
		verify(indexWriter).upsert(activeDocument(1L).refreshedAt(LocalDateTime.parse("2026-05-02T10:02:00")));
		verify(indexWriter).upsert(activeDocument(2L).refreshedAt(LocalDateTime.parse("2026-05-02T10:02:00")));
		verify(indexWriter).upsert(activeDocument(3L).refreshedAt(LocalDateTime.parse("2026-05-02T10:02:00")));
		verify(outboxStore).markDone(firstEvent);
		verify(outboxStore).markDone(secondEvent);
		verify(outboxStore).markDone(thirdEvent);
	}

	@Test
	void mixedRepeatedAndSingleProductIdsProcessOncePerProductId() {
		SearchOutboxEvent firstProductFirstEvent = event(30L, 1L, "PRODUCT_UPDATED", 0);
		SearchOutboxEvent secondProductEvent = event(31L, 2L, "PRODUCT_UPDATED", 0);
		SearchOutboxEvent firstProductSecondEvent = event(32L, 1L, "PRODUCT_STATUS_CHANGED", 0);
		when(outboxStore.claimPendingProductEvents(20, 60000L, "local-relay"))
				.thenReturn(List.of(firstProductFirstEvent, secondProductEvent, firstProductSecondEvent));
		when(documentRepository.findByProductId(1L)).thenReturn(Optional.of(activeDocument(1L)));
		when(documentRepository.findByProductId(2L)).thenReturn(Optional.of(activeDocument(2L)));

		relayService.processBatch();

		verify(documentRepository, times(1)).findByProductId(1L);
		verify(documentRepository, times(1)).findByProductId(2L);
		verify(indexWriter).upsert(activeDocument(1L).refreshedAt(LocalDateTime.parse("2026-05-02T10:02:00")));
		verify(indexWriter).upsert(activeDocument(2L).refreshedAt(LocalDateTime.parse("2026-05-02T10:02:00")));
		verify(outboxStore).markDone(firstProductFirstEvent);
		verify(outboxStore).markDone(secondProductEvent);
		verify(outboxStore).markDone(firstProductSecondEvent);
	}

	@Test
	void productIdGroupFailureDoesNotBlockOtherProductIdGroups() {
		SearchOutboxEvent failedFirstEvent = event(40L, 1L, "PRODUCT_UPDATED", 0);
		SearchOutboxEvent successfulEvent = event(41L, 2L, "PRODUCT_UPDATED", 0);
		SearchOutboxEvent failedSecondEvent = event(42L, 1L, "PRODUCT_STATUS_CHANGED", 0);
		when(outboxStore.claimPendingProductEvents(20, 60000L, "local-relay"))
				.thenReturn(List.of(failedFirstEvent, successfulEvent, failedSecondEvent));
		when(documentRepository.findByProductId(1L)).thenReturn(Optional.of(activeDocument(1L)));
		when(documentRepository.findByProductId(2L)).thenReturn(Optional.of(activeDocument(2L)));
		doThrow(new IllegalStateException("OpenSearch down"))
				.when(indexWriter)
				.upsert(activeDocument(1L).refreshedAt(LocalDateTime.parse("2026-05-02T10:02:00")));

		relayService.processBatch();

		verify(outboxStore).markPendingRetry(
				eq(failedFirstEvent),
				contains("OpenSearch down"),
				eq(LocalDateTime.parse("2026-05-02T10:02:10"))
		);
		verify(outboxStore).markPendingRetry(
				eq(failedSecondEvent),
				contains("OpenSearch down"),
				eq(LocalDateTime.parse("2026-05-02T10:02:10"))
		);
		verify(outboxStore).markDone(successfulEvent);
		verify(outboxStore, never()).markDone(failedFirstEvent);
		verify(outboxStore, never()).markDone(failedSecondEvent);
		verify(indexWriter).upsert(activeDocument(2L).refreshedAt(LocalDateTime.parse("2026-05-02T10:02:00")));
		assertTimingMetricsRecorded("pending_retry", 1L);
		assertTimingMetricsRecorded("done", 1L);
	}

	@Test
	void repeatedSameProductIdWithMissingOrInactiveLatestProductDeletesOnceAndMarksAllDone() {
		SearchOutboxEvent firstEvent = event(50L, 10L, "PRODUCT_UPDATED", 0);
		SearchOutboxEvent secondEvent = event(51L, 10L, "PRODUCT_STATUS_CHANGED", 0);
		when(outboxStore.claimPendingProductEvents(20, 60000L, "local-relay"))
				.thenReturn(List.of(firstEvent, secondEvent));
		when(documentRepository.findByProductId(10L)).thenReturn(Optional.of(deletedDocument()));

		relayService.processBatch();

		verify(documentRepository, times(1)).findByProductId(10L);
		verify(indexWriter, times(1)).deleteByProductId(10L);
		verify(indexWriter, never()).upsert(any());
		verify(outboxStore).markDone(firstEvent);
		verify(outboxStore).markDone(secondEvent);
		assertThat(timerCount("product_search_outbox_relay_opensearch_write", "done")).isEqualTo(1L);
		assertOnlyLowCardinalityTimingTags();
	}

	private void assertTimingMetricsRecorded(String result, long count) {
		assertThat(timerCount("product_search_outbox_relay_queue_wait", result)).isEqualTo(count);
		assertThat(timerCount("product_search_outbox_relay_source_document_load", result)).isEqualTo(count);
		assertThat(timerCount("product_search_outbox_relay_opensearch_write", result)).isEqualTo(count);
		assertThat(timerCount("product_search_outbox_relay_state_transition", result)).isEqualTo(count);
		assertThat(timerCount("product_search_outbox_relay_processing", result)).isEqualTo(count);
	}

	private long timerCount(String name, String result) {
		return meterRegistry.get(name)
				.tag("instance_id", "local-relay")
				.tag("result", result)
				.timer()
				.count();
	}

	private void assertOnlyLowCardinalityTimingTags() {
		List<String> timingMetricNames = List.of(
				"product_search_outbox_relay_queue_wait",
				"product_search_outbox_relay_source_document_load",
				"product_search_outbox_relay_opensearch_write",
				"product_search_outbox_relay_state_transition",
				"product_search_outbox_relay_processing"
		);
		assertThat(meterRegistry.getMeters())
				.filteredOn(meter -> timingMetricNames.contains(meter.getId().getName()))
				.flatExtracting(meter -> meter.getId().getTags().stream().map(tag -> tag.getKey()).toList())
				.containsOnly("instance_id", "result");
	}

	private static SearchOutboxEvent event(long id, String eventType, int retryCount) {
		return event(id, 10L, eventType, retryCount);
	}

	private static SearchOutboxEvent event(long id, long productId, String eventType, int retryCount) {
		return new SearchOutboxEvent(
				id,
				productId,
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
		return activeDocument(10L);
	}

	private static ProductSearchDocument activeDocument(long productId) {
		return document(productId, "ACTIVE");
	}

	private static ProductSearchDocument deletedDocument() {
		return document(10L, "DELETED");
	}

	private static ProductSearchDocument document(long productId, String status) {
		return new ProductSearchDocument(
				productId,
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
