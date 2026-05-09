package com.portfolio.marketplace.productsearch.repository;

import com.portfolio.marketplace.productsearch.domain.SearchOutboxEvent;
import java.time.LocalDateTime;
import java.time.OffsetDateTime;
import java.util.UUID;
import org.junit.jupiter.api.Test;

import static org.assertj.core.api.Assertions.assertThatCode;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

class SearchOutboxStoreTest {

	private static final String CLAIM_TOKEN = "00000000-0000-0000-0000-000000000001";

	private final SearchOutboxClaimDao claimDao = mock(SearchOutboxClaimDao.class);
	private final SearchOutboxJpaRepository jpaRepository = mock(SearchOutboxJpaRepository.class);
	private final SearchOutboxStore store = new SearchOutboxStore(claimDao, jpaRepository);

	@Test
	void markDoneUpdatesProcessingEventWithClaimToken() {
		SearchOutboxEvent event = event();
		when(jpaRepository.markDone(eq(1L), eq(UUID.fromString(CLAIM_TOKEN)), any(OffsetDateTime.class)))
				.thenReturn(1);

		store.markDone(event);

		verify(jpaRepository).markDone(eq(1L), eq(UUID.fromString(CLAIM_TOKEN)), any(OffsetDateTime.class));
	}

	@Test
	void markPendingRetryTruncatesLongErrorMessage() {
		SearchOutboxEvent event = event();
		when(jpaRepository.markPendingRetry(
				eq(1L),
				eq(UUID.fromString(CLAIM_TOKEN)),
				any(String.class),
				any(OffsetDateTime.class),
				any(OffsetDateTime.class)
		)).thenReturn(1);

		store.markPendingRetry(event, "x".repeat(1001), LocalDateTime.parse("2026-05-02T10:00:10"));

		verify(jpaRepository).markPendingRetry(
				eq(1L),
				eq(UUID.fromString(CLAIM_TOKEN)),
				eq("x".repeat(1000)),
				any(OffsetDateTime.class),
				any(OffsetDateTime.class)
		);
	}

	@Test
	void markFailedIgnoresStaleClaimToken() {
		SearchOutboxEvent event = event();
		when(jpaRepository.markFailed(
				eq(1L),
				eq(UUID.fromString(CLAIM_TOKEN)),
				any(String.class),
				any(OffsetDateTime.class)
		)).thenReturn(0);

		assertThatCode(() -> store.markFailed(event, "missing"))
				.doesNotThrowAnyException();

		verify(jpaRepository).markFailed(
				eq(1L),
				eq(UUID.fromString(CLAIM_TOKEN)),
				eq("missing"),
				any(OffsetDateTime.class)
		);
	}

	private static SearchOutboxEvent event() {
		return new SearchOutboxEvent(1L, 10L, "PRODUCT_UPDATED", 1, "{}", 0, CLAIM_TOKEN);
	}
}
