package com.portfolio.marketplace.productsearch.repository;

import com.portfolio.marketplace.productsearch.domain.SearchOutboxEvent;
import java.time.LocalDateTime;
import java.time.OffsetDateTime;
import java.time.ZoneOffset;
import java.util.List;
import org.springframework.stereotype.Repository;
import org.springframework.transaction.annotation.Transactional;

@Repository
public class SearchOutboxStore {

	private final SearchOutboxClaimDao searchOutboxClaimDao;
	private final SearchOutboxJpaRepository searchOutboxJpaRepository;

	public SearchOutboxStore(
			SearchOutboxClaimDao searchOutboxClaimDao,
			SearchOutboxJpaRepository searchOutboxJpaRepository
	) {
		this.searchOutboxClaimDao = searchOutboxClaimDao;
		this.searchOutboxJpaRepository = searchOutboxJpaRepository;
	}

	public List<SearchOutboxEvent> claimPendingProductEvents(int batchSize, long processingTimeoutMs) {
		return searchOutboxClaimDao.claimPendingProductEvents(batchSize, processingTimeoutMs);
	}

	@Transactional
	public void markDone(long eventId) {
		assertUpdated(eventId, searchOutboxJpaRepository.markDone(eventId, now()));
	}

	@Transactional
	public void markPendingRetry(long eventId, String lastError, LocalDateTime nextRetryAt) {
		int updated = searchOutboxJpaRepository.markPendingRetry(
				eventId,
				truncate(lastError),
				toOffsetDateTime(nextRetryAt),
				now()
		);
		assertUpdated(eventId, updated);
	}

	@Transactional
	public void markFailed(long eventId, String lastError) {
		assertUpdated(eventId, searchOutboxJpaRepository.markFailed(eventId, truncate(lastError), now()));
	}

	private static void assertUpdated(long eventId, int updated) {
		if (updated != 1) {
			throw new IllegalStateException("Search outbox event not found: " + eventId);
		}
	}

	private static OffsetDateTime toOffsetDateTime(LocalDateTime value) {
		return value.atOffset(ZoneOffset.UTC);
	}

	private static OffsetDateTime now() {
		return OffsetDateTime.now(ZoneOffset.UTC);
	}

	private static String truncate(String value) {
		if (value == null || value.length() <= 1000) {
			return value;
		}
		return value.substring(0, 1000);
	}
}
