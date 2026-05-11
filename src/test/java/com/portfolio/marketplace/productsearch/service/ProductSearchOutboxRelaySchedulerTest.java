package com.portfolio.marketplace.productsearch.service;

import com.portfolio.marketplace.productsearch.config.ProductSearchIndexingProperties;
import io.micrometer.core.instrument.simple.SimpleMeterRegistry;
import org.junit.jupiter.api.Test;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.times;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.verifyNoInteractions;
import static org.mockito.Mockito.when;

class ProductSearchOutboxRelaySchedulerTest {

	private final ProductSearchOutboxRelayService relayService = mock(ProductSearchOutboxRelayService.class);
	private final ProductSearchIndexingProperties properties = new ProductSearchIndexingProperties();
	private final SimpleMeterRegistry meterRegistry = new SimpleMeterRegistry();
	private final ProductSearchOutboxRelayScheduler scheduler = new ProductSearchOutboxRelayScheduler(
			relayService,
			properties,
			meterRegistry
	);

	@Test
	void skipsRelayWhenDisabled() {
		scheduler.relayPendingEvents();

		verifyNoInteractions(relayService);
	}

	@Test
	void defaultMaxDrainRoundsPreservesSingleBatchBehavior() {
		properties.getRelay().setEnabled(true);
		properties.getRelay().setBatchSize(100);
		when(relayService.processBatch()).thenReturn(100);

		scheduler.relayPendingEvents();

		verify(relayService).processBatch();
	}

	@Test
	void stopsWhenBatchIsNotFull() {
		properties.getRelay().setEnabled(true);
		properties.getRelay().setBatchSize(100);
		properties.getRelay().setMaxDrainRounds(5);
		when(relayService.processBatch()).thenReturn(60);

		scheduler.relayPendingEvents();

		verify(relayService).processBatch();
	}

	@Test
	void drainsUntilConfiguredRoundLimitWhileBatchesAreFull() {
		properties.getRelay().setEnabled(true);
		properties.getRelay().setBatchSize(100);
		properties.getRelay().setMaxDrainRounds(5);
		when(relayService.processBatch()).thenReturn(100, 100, 100, 100, 100);

		scheduler.relayPendingEvents();

		verify(relayService, times(5)).processBatch();
	}

	@Test
	void recordsMetricsForEmptySchedulerRun() {
		properties.getRelay().setEnabled(true);
		properties.getRelay().setBatchSize(100);
		properties.getRelay().setInstanceId("relay-a");
		when(relayService.processBatch()).thenReturn(0);

		scheduler.relayPendingEvents();

		assertThat(counter("product_search_outbox_relay_scheduler_runs_total", "result", "empty")).isEqualTo(1.0);
		assertThat(counter("product_search_outbox_relay_batch_attempts_total", "result", "empty")).isEqualTo(1.0);
		assertThat(counter("product_search_outbox_relay_processed_rows_total")).isZero();
		assertThat(summaryCount("product_search_outbox_relay_claim_rows")).isEqualTo(1L);
		assertThat(summaryTotal("product_search_outbox_relay_claim_rows")).isZero();
		assertThat(timerCount("product_search_outbox_relay_scheduler_run_duration_seconds")).isEqualTo(1L);
	}

	@Test
	void recordsMetricsForNonEmptySchedulerRun() {
		properties.getRelay().setEnabled(true);
		properties.getRelay().setBatchSize(100);
		properties.getRelay().setMaxDrainRounds(3);
		properties.getRelay().setInstanceId("relay-a");
		when(relayService.processBatch()).thenReturn(100, 40);

		scheduler.relayPendingEvents();

		assertThat(counter("product_search_outbox_relay_scheduler_runs_total", "result", "non_empty")).isEqualTo(1.0);
		assertThat(counter("product_search_outbox_relay_batch_attempts_total", "result", "non_empty")).isEqualTo(2.0);
		assertThat(counter("product_search_outbox_relay_processed_rows_total")).isEqualTo(140.0);
		assertThat(summaryCount("product_search_outbox_relay_claim_rows")).isEqualTo(2L);
		assertThat(summaryTotal("product_search_outbox_relay_claim_rows")).isEqualTo(140.0);
		assertThat(timerCount("product_search_outbox_relay_scheduler_run_duration_seconds")).isEqualTo(1L);
	}

	private double counter(String name, String tagKey, String tagValue) {
		return meterRegistry.get(name)
				.tag("instance_id", "relay-a")
				.tag(tagKey, tagValue)
				.counter()
				.count();
	}

	private double counter(String name) {
		return meterRegistry.get(name)
				.tag("instance_id", "relay-a")
				.counter()
				.count();
	}

	private long summaryCount(String name) {
		return meterRegistry.get(name)
				.tag("instance_id", "relay-a")
				.summary()
				.count();
	}

	private double summaryTotal(String name) {
		return meterRegistry.get(name)
				.tag("instance_id", "relay-a")
				.summary()
				.totalAmount();
	}

	private long timerCount(String name) {
		return meterRegistry.get(name)
				.tag("instance_id", "relay-a")
				.timer()
				.count();
	}
}
