package com.portfolio.marketplace.productsearch.repository;

import com.portfolio.marketplace.productsearch.domain.SearchOutboxEvent;
import java.time.LocalDateTime;
import java.util.List;
import java.util.Map;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.stereotype.Repository;

@Repository
public class SearchOutboxRepository {

	private final NamedParameterJdbcTemplate jdbcTemplate;

	public SearchOutboxRepository(NamedParameterJdbcTemplate jdbcTemplate) {
		this.jdbcTemplate = jdbcTemplate;
	}

	public List<SearchOutboxEvent> claimPendingProductEvents(int batchSize) {
		String sql = """
				WITH claimed AS (
				    SELECT id
				    FROM search_outbox
				    WHERE aggregate_type = 'PRODUCT'
				      AND status = 'PENDING'
				      AND (next_retry_at IS NULL OR next_retry_at <= now())
				    ORDER BY id
				    FOR UPDATE SKIP LOCKED
				    LIMIT :batchSize
				)
				UPDATE search_outbox outbox
				SET status = 'PROCESSING',
				    updated_at = now()
				FROM claimed
				WHERE outbox.id = claimed.id
				RETURNING
				    outbox.id,
				    outbox.aggregate_id,
				    outbox.event_type,
				    outbox.schema_version,
				    outbox.payload::text AS payload,
				    outbox.retry_count
				""";
		return jdbcTemplate.query(
				sql,
				Map.of("batchSize", batchSize),
				(rs, rowNum) -> new SearchOutboxEvent(
						rs.getLong("id"),
						rs.getLong("aggregate_id"),
						rs.getString("event_type"),
						rs.getInt("schema_version"),
						rs.getString("payload"),
						rs.getInt("retry_count")
				)
		);
	}

	public void markDone(long eventId) {
		String sql = """
				UPDATE search_outbox
				SET status = 'DONE',
				    last_error = NULL,
				    processed_at = now(),
				    updated_at = now()
				WHERE id = :eventId
				""";
		jdbcTemplate.update(sql, Map.of("eventId", eventId));
	}

	public void markPendingRetry(long eventId, String lastError, LocalDateTime nextRetryAt) {
		String sql = """
				UPDATE search_outbox
				SET status = 'PENDING',
				    retry_count = retry_count + 1,
				    last_error = :lastError,
				    next_retry_at = :nextRetryAt,
				    updated_at = now()
				WHERE id = :eventId
				""";
		jdbcTemplate.update(sql, Map.of(
				"eventId", eventId,
				"lastError", truncate(lastError),
				"nextRetryAt", nextRetryAt
		));
	}

	public void markFailed(long eventId, String lastError) {
		String sql = """
				UPDATE search_outbox
				SET status = 'FAILED',
				    retry_count = retry_count + 1,
				    last_error = :lastError,
				    next_retry_at = NULL,
				    processed_at = now(),
				    updated_at = now()
				WHERE id = :eventId
				""";
		jdbcTemplate.update(sql, Map.of(
				"eventId", eventId,
				"lastError", truncate(lastError)
		));
	}

	private static String truncate(String value) {
		if (value == null || value.length() <= 1000) {
			return value;
		}
		return value.substring(0, 1000);
	}
}
