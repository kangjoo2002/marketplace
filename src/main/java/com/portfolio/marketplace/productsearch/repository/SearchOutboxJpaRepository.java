package com.portfolio.marketplace.productsearch.repository;

import com.portfolio.marketplace.productsearch.domain.SearchOutbox;
import java.time.OffsetDateTime;
import java.util.UUID;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Modifying;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;

public interface SearchOutboxJpaRepository extends JpaRepository<SearchOutbox, Long> {

	@Modifying
	@Query("""
			UPDATE SearchOutbox outbox
			SET outbox.status = com.portfolio.marketplace.productsearch.domain.SearchOutboxStatus.DONE,
			    outbox.lastError = NULL,
			    outbox.claimToken = NULL,
			    outbox.processedAt = :now,
			    outbox.updatedAt = :now
			WHERE outbox.id = :eventId
			  AND outbox.status = com.portfolio.marketplace.productsearch.domain.SearchOutboxStatus.PROCESSING
			  AND outbox.claimToken = :claimToken
			""")
	int markDone(
			@Param("eventId") long eventId,
			@Param("claimToken") UUID claimToken,
			@Param("now") OffsetDateTime now
	);

	@Modifying
	@Query("""
			UPDATE SearchOutbox outbox
			SET outbox.status = com.portfolio.marketplace.productsearch.domain.SearchOutboxStatus.PENDING,
			    outbox.retryCount = outbox.retryCount + 1,
			    outbox.lastError = :lastError,
			    outbox.claimToken = NULL,
			    outbox.nextRetryAt = :nextRetryAt,
			    outbox.updatedAt = :now
			WHERE outbox.id = :eventId
			  AND outbox.status = com.portfolio.marketplace.productsearch.domain.SearchOutboxStatus.PROCESSING
			  AND outbox.claimToken = :claimToken
			""")
	int markPendingRetry(
			@Param("eventId") long eventId,
			@Param("claimToken") UUID claimToken,
			@Param("lastError") String lastError,
			@Param("nextRetryAt") OffsetDateTime nextRetryAt,
			@Param("now") OffsetDateTime now
	);

	@Modifying
	@Query("""
			UPDATE SearchOutbox outbox
			SET outbox.status = com.portfolio.marketplace.productsearch.domain.SearchOutboxStatus.FAILED,
			    outbox.retryCount = outbox.retryCount + 1,
			    outbox.lastError = :lastError,
			    outbox.claimToken = NULL,
			    outbox.nextRetryAt = NULL,
			    outbox.processedAt = :now,
			    outbox.updatedAt = :now
			WHERE outbox.id = :eventId
			  AND outbox.status = com.portfolio.marketplace.productsearch.domain.SearchOutboxStatus.PROCESSING
			  AND outbox.claimToken = :claimToken
			""")
	int markFailed(
			@Param("eventId") long eventId,
			@Param("claimToken") UUID claimToken,
			@Param("lastError") String lastError,
			@Param("now") OffsetDateTime now
	);
}
