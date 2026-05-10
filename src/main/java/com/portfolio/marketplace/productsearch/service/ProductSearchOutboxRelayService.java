package com.portfolio.marketplace.productsearch.service;

import com.portfolio.marketplace.productsearch.config.ProductSearchIndexingProperties;
import com.portfolio.marketplace.productsearch.domain.ProductSearchDocument;
import com.portfolio.marketplace.productsearch.domain.SearchOutboxEvent;
import com.portfolio.marketplace.productsearch.repository.ProductSearchDocumentRepository;
import com.portfolio.marketplace.productsearch.repository.SearchOutboxStore;
import com.portfolio.marketplace.productsearch.service.port.ProductSearchIndexWriter;
import java.time.Clock;
import java.time.LocalDateTime;
import java.util.List;
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
				relay.getProcessingTimeoutMs()
		);
		for (SearchOutboxEvent event : events) {
			processEvent(event);
		}
		return events.size();
	}

	private void processEvent(SearchOutboxEvent event) {
		try {
			if (event.isProductDeleteEvent()) {
				indexWriter.deleteByProductId(event.aggregateId());
				outboxStore.markDone(event);
				return;
			}

			documentRepository.findByProductId(event.aggregateId())
					.map(this::refresh)
					.ifPresentOrElse(
							this::upsertOrDeleteDeletedDocument,
							() -> indexWriter.deleteByProductId(event.aggregateId())
					);
			outboxStore.markDone(event);
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
			markFailure(event, errorMessage);
		}
	}

	private void markFailure(SearchOutboxEvent event, String errorMessage) {
		if (event.retryCount() + 1 >= indexingProperties.getRelay().getMaxRetryCount()) {
			outboxStore.markFailed(event, errorMessage);
			return;
		}
		LocalDateTime nextRetryAt = LocalDateTime.now(clock)
				.plusNanos(indexingProperties.getRelay().getRetryDelayMs() * 1_000_000);
		outboxStore.markPendingRetry(event, errorMessage, nextRetryAt);
	}

	private ProductSearchDocument refresh(ProductSearchDocument document) {
		return document.refreshedAt(LocalDateTime.now(clock));
	}

	private void upsertOrDeleteDeletedDocument(ProductSearchDocument document) {
		if (document.isDeleted()) {
			indexWriter.deleteByProductId(document.productId());
			return;
		}
		indexWriter.upsert(document);
	}
}
