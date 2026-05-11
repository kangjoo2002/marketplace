package com.portfolio.marketplace.productsearch.service;

import com.portfolio.marketplace.productsearch.config.ProductSearchIndexingProperties;
import com.portfolio.marketplace.productsearch.domain.ProductSearchDocument;
import com.portfolio.marketplace.productsearch.domain.SearchOutboxEvent;
import com.portfolio.marketplace.productsearch.repository.ProductSearchDocumentRepository;
import com.portfolio.marketplace.productsearch.repository.SearchOutboxStore;
import com.portfolio.marketplace.productsearch.service.port.ProductSearchIndexWriter;
import java.time.Clock;
import java.time.Duration;
import java.time.LocalDateTime;
import java.util.List;
import java.util.Optional;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Service;

@Service
public class ProductSearchOutboxRelayService {

	private static final Logger log = LoggerFactory.getLogger(ProductSearchOutboxRelayService.class);

	private final SearchOutboxStore outboxStore;
	private final ProductSearchDocumentRepository documentRepository;
	private final ProductSearchIndexWriter indexWriter;
	private final ProductSearchIndexingProperties indexingProperties;
	private final Clock clock;

	public ProductSearchOutboxRelayService(
			SearchOutboxStore outboxStore,
			ProductSearchDocumentRepository documentRepository,
			ProductSearchIndexWriter indexWriter,
			ProductSearchIndexingProperties indexingProperties,
			Clock clock
	) {
		this.outboxStore = outboxStore;
		this.documentRepository = documentRepository;
		this.indexWriter = indexWriter;
		this.indexingProperties = indexingProperties;
		this.clock = clock;
	}

	public int processBatch() {
		ProductSearchIndexingProperties.Relay relay = indexingProperties.getRelay();
		List<SearchOutboxEvent> events = outboxStore.claimPendingProductEvents(
				relay.getBatchSize(),
				relay.getProcessingTimeoutMs(),
				relay.getInstanceId()
		);
		for (SearchOutboxEvent event : events) {
			processEvent(event);
		}
		return events.size();
	}

	private void processEvent(SearchOutboxEvent event) {
		IndexingLatencyMeasurement measurement = new IndexingLatencyMeasurement(event);
		try {
			if (event.isProductDeleteEvent()) {
				long openSearchWriteStartedAt = System.nanoTime();
				indexWriter.deleteByProductId(event.aggregateId());
				measurement.recordOpenSearchWrite(openSearchWriteStartedAt);
				markDone(event, measurement);
				measurement.log("DONE");
				return;
			}

			long sourceDocumentLoadStartedAt = System.nanoTime();
			Optional<ProductSearchDocument> document = documentRepository.findByProductId(event.aggregateId());
			measurement.recordSourceDocumentLoad(sourceDocumentLoadStartedAt);
			document
					.map(this::refresh)
					.ifPresentOrElse(
							value -> upsertOrDeleteDeletedDocument(value, measurement),
							() -> deleteByProductId(event.aggregateId(), measurement)
					);
			markDone(event, measurement);
			measurement.log("DONE");
		} catch (RuntimeException exception) {
			String errorMessage = exception.getMessage() == null
					? exception.getClass().getSimpleName()
					: exception.getMessage();
			log.warn(
					"Failed to relay product search outbox event. eventId={}, aggregateId={}, eventType={}",
					event.id(),
					event.aggregateId(),
					event.eventType(),
					exception
			);
			markFailure(event, errorMessage, measurement);
		}
	}

	private void markFailure(SearchOutboxEvent event, String errorMessage, IndexingLatencyMeasurement measurement) {
		if (event.retryCount() + 1 >= indexingProperties.getRelay().getMaxRetryCount()) {
			long outboxStateTransitionStartedAt = System.nanoTime();
			outboxStore.markFailed(event, errorMessage);
			measurement.recordOutboxStateTransition(outboxStateTransitionStartedAt);
			measurement.log("FAILED");
			return;
		}
		LocalDateTime nextRetryAt = LocalDateTime.now(clock)
				.plusNanos(indexingProperties.getRelay().getRetryDelayMs() * 1_000_000);
		long outboxStateTransitionStartedAt = System.nanoTime();
		outboxStore.markPendingRetry(event, errorMessage, nextRetryAt);
		measurement.recordOutboxStateTransition(outboxStateTransitionStartedAt);
		measurement.log("PENDING_RETRY");
	}

	private ProductSearchDocument refresh(ProductSearchDocument document) {
		return document.refreshedAt(LocalDateTime.now(clock));
	}

	private void upsertOrDeleteDeletedDocument(
			ProductSearchDocument document,
			IndexingLatencyMeasurement measurement
	) {
		if (document.isDeleted()) {
			deleteByProductId(document.productId(), measurement);
			return;
		}
		long openSearchWriteStartedAt = System.nanoTime();
		indexWriter.upsert(document);
		measurement.recordOpenSearchWrite(openSearchWriteStartedAt);
	}

	private void deleteByProductId(long productId, IndexingLatencyMeasurement measurement) {
		long openSearchWriteStartedAt = System.nanoTime();
		indexWriter.deleteByProductId(productId);
		measurement.recordOpenSearchWrite(openSearchWriteStartedAt);
	}

	private void markDone(SearchOutboxEvent event, IndexingLatencyMeasurement measurement) {
		long outboxStateTransitionStartedAt = System.nanoTime();
		outboxStore.markDone(event);
		measurement.recordOutboxStateTransition(outboxStateTransitionStartedAt);
	}

	private static long elapsedMillis(long startedAtNanos) {
		return Duration.ofNanos(System.nanoTime() - startedAtNanos).toMillis();
	}

	private static long elapsedMillis(long startedAtNanos, long endedAtNanos) {
		return Duration.ofNanos(endedAtNanos - startedAtNanos).toMillis();
	}

	private static long queueWaitMillis(SearchOutboxEvent event) {
		if (event.createdAt() == null || event.claimedAt() == null) {
			return -1L;
		}
		return Math.max(0L, Duration.between(event.createdAt(), event.claimedAt()).toMillis());
	}

	private static class IndexingLatencyMeasurement {

		private final SearchOutboxEvent event;
		private final long relayProcessingStartedAtNanos = System.nanoTime();

		private long sourceDocumentLoadMs;
		private long openSearchWriteMs;
		private long outboxStateTransitionMs;

		private IndexingLatencyMeasurement(SearchOutboxEvent event) {
			this.event = event;
		}

		private void recordSourceDocumentLoad(long startedAtNanos) {
			sourceDocumentLoadMs += elapsedMillis(startedAtNanos);
		}

		private void recordOpenSearchWrite(long startedAtNanos) {
			openSearchWriteMs += elapsedMillis(startedAtNanos);
		}

		private void recordOutboxStateTransition(long startedAtNanos) {
			outboxStateTransitionMs += elapsedMillis(startedAtNanos);
		}

		private void log(String resultStatus) {
			long completedAtNanos = System.nanoTime();
			log.info(
					"product_search_outbox_indexing_latency eventId={} aggregateId={} eventType={} resultStatus={} "
							+ "queueWaitMs={} sourceDocumentLoadMs={} openSearchWriteMs={} "
							+ "outboxStateTransitionMs={} relayProcessingMs={}",
					event.id(),
					event.aggregateId(),
					event.eventType(),
					resultStatus,
					queueWaitMillis(event),
					sourceDocumentLoadMs,
					openSearchWriteMs,
					outboxStateTransitionMs,
					elapsedMillis(relayProcessingStartedAtNanos, completedAtNanos)
			);
		}
	}
}
