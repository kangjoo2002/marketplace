package com.portfolio.marketplace.productsearch.repository;

import com.portfolio.marketplace.productsearch.domain.SearchOutboxEvent;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.stereotype.Repository;

@Repository
public class SearchOutboxClaimDao {

	private final NamedParameterJdbcTemplate jdbcTemplate;

	public SearchOutboxClaimDao(NamedParameterJdbcTemplate jdbcTemplate) {
		this.jdbcTemplate = jdbcTemplate;
	}

	public List<SearchOutboxEvent> claimPendingProductEvents(int batchSize, long processingTimeoutMs) {
		UUID claimToken = UUID.randomUUID();
		String sql = """
				WITH claimed AS (
				    SELECT id
				    FROM search_outbox
				    WHERE aggregate_type = 'PRODUCT'
				      AND (
				          (
				              status = 'PENDING'
				              AND (next_retry_at IS NULL OR next_retry_at <= now())
				          )
				          OR (
				              status = 'PROCESSING'
				              AND updated_at <= now() - (:processingTimeoutMs * INTERVAL '1 millisecond')
				          )
				      )
				    ORDER BY id
				    FOR UPDATE SKIP LOCKED
				    LIMIT :batchSize
				)
				UPDATE search_outbox outbox
				SET status = 'PROCESSING',
				    claim_token = :claimToken,
				    next_retry_at = NULL,
				    updated_at = now()
				FROM claimed
				WHERE outbox.id = claimed.id
				RETURNING
				    outbox.id,
				    outbox.aggregate_id,
				    outbox.event_type,
				    outbox.schema_version,
				    outbox.payload::text AS payload,
				    outbox.retry_count,
				    outbox.claim_token::text AS claim_token,
				    outbox.created_at,
				    outbox.updated_at AS claimed_at
				""";
		return jdbcTemplate.query(
				sql,
				Map.of(
						"batchSize", batchSize,
						"processingTimeoutMs", processingTimeoutMs,
						"claimToken", claimToken
				),
				(rs, rowNum) -> new SearchOutboxEvent(
						rs.getLong("id"),
						rs.getLong("aggregate_id"),
						rs.getString("event_type"),
						rs.getInt("schema_version"),
						rs.getString("payload"),
						rs.getInt("retry_count"),
						rs.getString("claim_token"),
						rs.getObject("created_at", java.time.OffsetDateTime.class),
						rs.getObject("claimed_at", java.time.OffsetDateTime.class)
				)
		);
	}
}
