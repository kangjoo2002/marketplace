package com.portfolio.marketplace.productsearch.repository;

import com.portfolio.marketplace.productsearch.domain.SearchOutboxEvent;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;
import org.mockito.ArgumentMatchers;
import org.springframework.jdbc.core.RowMapper;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;

import static org.assertj.core.api.Assertions.assertThatCode;
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
		assertThat(sql).contains("claim_token = :claimToken");
		assertThat(sql).contains("next_retry_at = NULL");
		assertThat(sql).contains("outbox.claim_token::text AS claim_token");
		assertThat(params).containsEntry("batchSize", 20);
		assertThat(params).containsEntry("processingTimeoutMs", 60000L);
		assertThat(params).containsKey("claimToken");
		assertThat(params.get("claimToken")).isInstanceOf(UUID.class);
	}

	@Test
	@SuppressWarnings("unchecked")
	void concurrentClaimAttemptsUseDistinctClaimTokensAndSkipLockedLeaseQuery() throws Exception {
		NamedParameterJdbcTemplate jdbcTemplate = mock(NamedParameterJdbcTemplate.class);
		List<String> sqls = Collections.synchronizedList(new ArrayList<>());
		List<Map<String, Object>> params = Collections.synchronizedList(new ArrayList<>());
		CountDownLatch ready = new CountDownLatch(2);
		CountDownLatch start = new CountDownLatch(1);
		when(jdbcTemplate.query(
				ArgumentMatchers.anyString(),
				ArgumentMatchers.<Map<String, Object>>any(),
				ArgumentMatchers.<RowMapper<SearchOutboxEvent>>any()
		)).thenAnswer(invocation -> {
			ready.countDown();
			assertThatCode(() -> start.await(1, TimeUnit.SECONDS)).doesNotThrowAnyException();
			sqls.add(invocation.getArgument(0));
			params.add(invocation.getArgument(1));
			return List.of();
		});
		SearchOutboxClaimDao claimDao = new SearchOutboxClaimDao(jdbcTemplate);
		ExecutorService executor = Executors.newFixedThreadPool(2);

		executor.submit(() -> claimDao.claimPendingProductEvents(1, 60000L));
		executor.submit(() -> claimDao.claimPendingProductEvents(1, 60000L));
		assertThat(ready.await(1, TimeUnit.SECONDS)).isTrue();
		start.countDown();
		executor.shutdown();

		assertThat(executor.awaitTermination(1, TimeUnit.SECONDS)).isTrue();
		assertThat(sqls).hasSize(2).allSatisfy(sql -> {
			assertThat(sql).contains("FOR UPDATE SKIP LOCKED");
			assertThat(sql).contains("LIMIT :batchSize");
			assertThat(sql).contains("claim_token = :claimToken");
			assertThat(sql).contains("status = 'PENDING'");
			assertThat(sql).contains("status = 'PROCESSING'");
		});
		assertThat(params).hasSize(2);
		assertThat(params)
				.extracting(parameterMap -> parameterMap.get("claimToken"))
				.doesNotHaveDuplicates()
				.allSatisfy(token -> assertThat(token).isInstanceOf(UUID.class));
	}
}
