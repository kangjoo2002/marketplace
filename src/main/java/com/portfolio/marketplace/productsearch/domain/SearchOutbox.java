package com.portfolio.marketplace.productsearch.domain;

import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.EnumType;
import jakarta.persistence.Enumerated;
import jakarta.persistence.GeneratedValue;
import jakarta.persistence.GenerationType;
import jakarta.persistence.Id;
import jakarta.persistence.Table;
import java.time.OffsetDateTime;
import java.util.UUID;

@Entity
@Table(name = "search_outbox")
public class SearchOutbox {

	@Id
	@GeneratedValue(strategy = GenerationType.IDENTITY)
	private Long id;

	@Enumerated(EnumType.STRING)
	@Column(name = "aggregate_type", nullable = false, length = 40)
	private SearchOutboxAggregateType aggregateType;

	@Column(name = "aggregate_id", nullable = false)
	private Long aggregateId;

	@Enumerated(EnumType.STRING)
	@Column(name = "event_type", nullable = false, length = 80)
	private SearchOutboxEventType eventType;

	@Column(name = "schema_version", nullable = false)
	private Integer schemaVersion;

	@Column(nullable = false, columnDefinition = "jsonb")
	private String payload;

	@Enumerated(EnumType.STRING)
	@Column(nullable = false, length = 20)
	private SearchOutboxStatus status;

	@Column(name = "retry_count", nullable = false)
	private Integer retryCount;

	@Column(name = "claim_token")
	private UUID claimToken;

	@Column(name = "last_error")
	private String lastError;

	@Column(name = "next_retry_at")
	private OffsetDateTime nextRetryAt;

	@Column(name = "created_at", nullable = false)
	private OffsetDateTime createdAt;

	@Column(name = "updated_at", nullable = false)
	private OffsetDateTime updatedAt;

	@Column(name = "processed_at")
	private OffsetDateTime processedAt;

	protected SearchOutbox() {
	}

	public Long getId() {
		return id;
	}

	public SearchOutboxStatus getStatus() {
		return status;
	}

	public Integer getRetryCount() {
		return retryCount;
	}

	public String getLastError() {
		return lastError;
	}

	public OffsetDateTime getNextRetryAt() {
		return nextRetryAt;
	}

	public OffsetDateTime getProcessedAt() {
		return processedAt;
	}
}
