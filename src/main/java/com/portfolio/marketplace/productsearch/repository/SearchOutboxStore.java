package com.portfolio.marketplace.productsearch.repository;

import com.portfolio.marketplace.productsearch.domain.SearchOutboxEvent;
import java.time.LocalDateTime;
import java.time.OffsetDateTime;
import java.time.ZoneOffset;
import java.util.List;
import java.util.UUID;
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
	public void markDone(SearchOutboxEvent event) {
		searchOutboxJpaRepository.markDone(event.id(), claimToken(event), now());
	}

	@Transactional
	public void markPendingRetry(SearchOutboxEvent event, String lastError, LocalDateTime nextRetryAt) {
		searchOutboxJpaRepository.markPendingRetry(
				event.id(),
				claimToken(event),
				truncate(lastError),
				toOffsetDateTime(nextRetryAt),
				now()
		);
	}

	@Transactional
	public void markFailed(SearchOutboxEvent event, String lastError) {
		searchOutboxJpaRepository.markFailed(event.id(), claimToken(event), truncate(lastError), now());
	}

	private static UUID claimToken(SearchOutboxEvent event) {
		return UUID.fromString(event.claimToken());
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
