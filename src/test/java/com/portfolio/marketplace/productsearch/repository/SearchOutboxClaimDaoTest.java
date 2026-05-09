package com.portfolio.marketplace.productsearch.repository;

import com.portfolio.marketplace.productsearch.domain.SearchOutboxEvent;
import java.util.List;
import java.util.Map;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;
import org.mockito.ArgumentMatchers;
import org.springframework.jdbc.core.RowMapper;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

class SearchOutboxClaimDaoTest {

	@Test
	@SuppressWarnings("unchecked")
	void claimIncludesPendingRetryAndStaleProcessingLease() {
		NamedParameterJdbcTemplate jdbcTemplate = mock(NamedParameterJdbcTemplate.class);
		ArgumentCaptor<String> sqlCaptor = ArgumentCaptor.forClass(String.class);
		ArgumentCaptor<Map<String, Object>> paramsCaptor = ArgumentCaptor.forClass(Map.class);
		when(jdbcTemplate.query(
				sqlCaptor.capture(),
				paramsCaptor.capture(),
				ArgumentMatchers.<RowMapper<SearchOutboxEvent>>any()
		)).thenReturn(List.of());
		SearchOutboxClaimDao claimDao = new SearchOutboxClaimDao(jdbcTemplate);

		claimDao.claimPendingProductEvents(20, 60000L);

		String sql = sqlCaptor.getValue();
		Map<String, Object> params = paramsCaptor.getValue();
		assertThat(sql).contains("status = 'PENDING'");
		assertThat(sql).contains("next_retry_at IS NULL OR next_retry_at <= now()");
		assertThat(sql).contains("status = 'PROCESSING'");
		assertThat(sql).contains("updated_at <= now() - (:processingTimeoutMs * INTERVAL '1 millisecond')");
		assertThat(sql).contains("FOR UPDATE SKIP LOCKED");
		assertThat(sql).contains("next_retry_at = NULL");
		assertThat(params).containsEntry("batchSize", 20);
		assertThat(params).containsEntry("processingTimeoutMs", 60000L);
	}
}
