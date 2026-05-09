package com.portfolio.marketplace.productsearch.repository;

import java.time.LocalDateTime;
import java.time.OffsetDateTime;
import org.junit.jupiter.api.Test;

import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

class SearchOutboxStoreTest {

	private final SearchOutboxClaimDao claimDao = mock(SearchOutboxClaimDao.class);
	private final SearchOutboxJpaRepository jpaRepository = mock(SearchOutboxJpaRepository.class);
	private final SearchOutboxStore store = new SearchOutboxStore(claimDao, jpaRepository);

	@Test
	void markDoneUpdatesOnlyStatusColumnsThroughJpaRepository() {
		when(jpaRepository.markDone(eq(1L), any(OffsetDateTime.class))).thenReturn(1);

		store.markDone(1L);

		verify(jpaRepository).markDone(eq(1L), any(OffsetDateTime.class));
	}

	@Test
	void markPendingRetryTruncatesLongErrorMessage() {
		when(jpaRepository.markPendingRetry(
				eq(1L),
				any(String.class),
				any(OffsetDateTime.class),
				any(OffsetDateTime.class)
		)).thenReturn(1);

		store.markPendingRetry(1L, "x".repeat(1001), LocalDateTime.parse("2026-05-02T10:00:10"));

		verify(jpaRepository).markPendingRetry(
				eq(1L),
				eq("x".repeat(1000)),
				any(OffsetDateTime.class),
				any(OffsetDateTime.class)
		);
	}

	@Test
	void markFailedThrowsWhenEventDoesNotExist() {
		when(jpaRepository.markFailed(eq(1L), any(String.class), any(OffsetDateTime.class))).thenReturn(0);

		assertThatThrownBy(() -> store.markFailed(1L, "missing"))
				.isInstanceOf(IllegalStateException.class)
				.hasMessageContaining("Search outbox event not found");
	}
}
