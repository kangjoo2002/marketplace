package com.portfolio.marketplace.productsearch.repository;

import com.portfolio.marketplace.productsearch.domain.SearchOutboxEvent;
import java.time.LocalDateTime;
import java.time.OffsetDateTime;
import java.util.UUID;
import org.junit.jupiter.api.extension.ExtendWith;
import org.junit.jupiter.api.Test;
import org.springframework.boot.test.system.CapturedOutput;
import org.springframework.boot.test.system.OutputCaptureExtension;

import static org.assertj.core.api.Assertions.assertThatCode;
import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

@ExtendWith(OutputCaptureExtension.class)
class SearchOutboxStoreTest {

	private static final String CLAIM_TOKEN = "00000000-0000-0000-0000-000000000001";
	private static final String STALE_CLAIM_TOKEN = "00000000-0000-0000-0000-000000000099";

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
	void markDoneIgnoresStaleClaimTokenAndLogs(CapturedOutput output) {
		SearchOutboxEvent event = event();
		when(jpaRepository.markDone(
				eq(1L),
				eq(UUID.fromString(CLAIM_TOKEN)),
				any(OffsetDateTime.class)
		)).thenReturn(0);

		assertThatCode(() -> store.markDone(event))
				.doesNotThrowAnyException();

		verify(jpaRepository).markDone(eq(1L), eq(UUID.fromString(CLAIM_TOKEN)), any(OffsetDateTime.class));
		assertThat(output.getOut())
				.contains("Search outbox transition skipped by stale claim token")
				.contains("eventId=1")
				.contains("targetStatus=DONE")
				.contains("claimToken=" + CLAIM_TOKEN);
	}

	@Test
	void markFailedIgnoresStaleClaimTokenAndLogs(CapturedOutput output) {
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
		assertThat(output.getOut())
				.contains("Search outbox transition skipped by stale claim token")
				.contains("eventId=1")
				.contains("targetStatus=FAILED")
				.contains("claimToken=" + CLAIM_TOKEN);
	}

	@Test
	void markPendingRetryIgnoresStaleClaimTokenAndLogs(CapturedOutput output) {
		SearchOutboxEvent event = event();
		when(jpaRepository.markPendingRetry(
				eq(1L),
				eq(UUID.fromString(CLAIM_TOKEN)),
				eq("retry"),
				any(OffsetDateTime.class),
				any(OffsetDateTime.class)
		)).thenReturn(0);

		assertThatCode(() -> store.markPendingRetry(
				event,
				"retry",
				LocalDateTime.parse("2026-05-02T10:00:10")
		)).doesNotThrowAnyException();

		verify(jpaRepository).markPendingRetry(
				eq(1L),
				eq(UUID.fromString(CLAIM_TOKEN)),
				eq("retry"),
				any(OffsetDateTime.class),
				any(OffsetDateTime.class)
		);
		assertThat(output.getOut())
				.contains("Search outbox transition skipped by stale claim token")
				.contains("eventId=1")
				.contains("targetStatus=PENDING")
				.contains("claimToken=" + CLAIM_TOKEN);
	}

	@Test
	void oldWorkerLateCompletionCannotOverwriteNewerClaimToken() {
		SearchOutboxEvent staleWorkerEvent = event(STALE_CLAIM_TOKEN);
		SearchOutboxEvent currentWorkerEvent = event(CLAIM_TOKEN);
		when(jpaRepository.markDone(
				eq(1L),
				eq(UUID.fromString(STALE_CLAIM_TOKEN)),
				any(OffsetDateTime.class)
		)).thenReturn(0);
		when(jpaRepository.markDone(
				eq(1L),
				eq(UUID.fromString(CLAIM_TOKEN)),
				any(OffsetDateTime.class)
		)).thenReturn(1);
		when(jpaRepository.markFailed(
				eq(1L),
				eq(UUID.fromString(STALE_CLAIM_TOKEN)),
				any(String.class),
				any(OffsetDateTime.class)
		)).thenReturn(0);
		when(jpaRepository.markPendingRetry(
				eq(1L),
				eq(UUID.fromString(STALE_CLAIM_TOKEN)),
				any(String.class),
				any(OffsetDateTime.class),
				any(OffsetDateTime.class)
		)).thenReturn(0);

		store.markDone(staleWorkerEvent);
		store.markFailed(staleWorkerEvent, "late failure");
		store.markPendingRetry(staleWorkerEvent, "late retry", LocalDateTime.parse("2026-05-02T10:00:10"));
		store.markDone(currentWorkerEvent);

		verify(jpaRepository).markDone(eq(1L), eq(UUID.fromString(STALE_CLAIM_TOKEN)), any(OffsetDateTime.class));
		verify(jpaRepository).markFailed(
				eq(1L),
				eq(UUID.fromString(STALE_CLAIM_TOKEN)),
				eq("late failure"),
				any(OffsetDateTime.class)
		);
		verify(jpaRepository).markPendingRetry(
				eq(1L),
				eq(UUID.fromString(STALE_CLAIM_TOKEN)),
				eq("late retry"),
				any(OffsetDateTime.class),
				any(OffsetDateTime.class)
		);
		verify(jpaRepository).markDone(eq(1L), eq(UUID.fromString(CLAIM_TOKEN)), any(OffsetDateTime.class));
	}

	private static SearchOutboxEvent event() {
		return event(CLAIM_TOKEN);
	}

	private static SearchOutboxEvent event(String claimToken) {
		return new SearchOutboxEvent(1L, 10L, "PRODUCT_UPDATED", 1, "{}", 0, claimToken);
	}
}
