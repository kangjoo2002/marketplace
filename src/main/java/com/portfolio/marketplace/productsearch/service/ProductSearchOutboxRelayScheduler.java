package com.portfolio.marketplace.productsearch.service;

import com.portfolio.marketplace.productsearch.config.ProductSearchIndexingProperties;
import io.micrometer.core.instrument.DistributionSummary;
import io.micrometer.core.instrument.MeterRegistry;
import io.micrometer.core.instrument.Timer;
import java.util.concurrent.TimeUnit;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;

@Component
public class ProductSearchOutboxRelayScheduler {

	private static final String RESULT_EMPTY = "empty";
	private static final String RESULT_NON_EMPTY = "non_empty";

	private final ProductSearchOutboxRelayService relayService;
	private final ProductSearchIndexingProperties indexingProperties;
	private final MeterRegistry meterRegistry;

	public ProductSearchOutboxRelayScheduler(
			ProductSearchOutboxRelayService relayService,
			ProductSearchIndexingProperties indexingProperties,
			MeterRegistry meterRegistry
	) {
		this.relayService = relayService;
		this.indexingProperties = indexingProperties;
		this.meterRegistry = meterRegistry;
	}

	@Scheduled(fixedDelayString = "${readpath.product-search.indexing.relay.fixed-delay-ms:5000}")
	public void relayPendingEvents() {
		if (!indexingProperties.getRelay().isEnabled()) {
			return;
		}
		ProductSearchIndexingProperties.Relay relay = indexingProperties.getRelay();
		int maxDrainRounds = Math.max(1, relay.getMaxDrainRounds());
		long startedAtNanos = System.nanoTime();
		int totalProcessedCount = 0;
		for (int round = 0; round < maxDrainRounds; round++) {
			int processedCount = relayService.processBatch();
			totalProcessedCount += processedCount;
			recordBatchAttempt(relay.getInstanceId(), processedCount);
			if (processedCount < relay.getBatchSize()) {
				recordSchedulerRun(relay.getInstanceId(), totalProcessedCount, startedAtNanos);
				return;
			}
		}
		recordSchedulerRun(relay.getInstanceId(), totalProcessedCount, startedAtNanos);
	}

	private void recordBatchAttempt(String instanceId, int processedCount) {
		String result = result(processedCount);
		meterRegistry.counter(
				"product_search_outbox_relay_batch_attempts_total",
				"instance_id",
				instanceId,
				"result",
				result
		).increment();
		meterRegistry.counter(
				"product_search_outbox_relay_processed_rows_total",
				"instance_id",
				instanceId
		).increment(processedCount);
		DistributionSummary.builder("product_search_outbox_relay_claim_rows")
				.tag("instance_id", instanceId)
				.publishPercentiles(0.5, 0.95)
				.register(meterRegistry)
				.record(processedCount);
	}

	private void recordSchedulerRun(String instanceId, int totalProcessedCount, long startedAtNanos) {
		meterRegistry.counter(
				"product_search_outbox_relay_scheduler_runs_total",
				"instance_id",
				instanceId,
				"result",
				result(totalProcessedCount)
		).increment();
		Timer.builder("product_search_outbox_relay_scheduler_run_duration")
				.tag("instance_id", instanceId)
				.publishPercentiles(0.95)
				.register(meterRegistry)
				.record(System.nanoTime() - startedAtNanos, TimeUnit.NANOSECONDS);
	}

	private static String result(int processedCount) {
		if (processedCount == 0) {
			return RESULT_EMPTY;
		}
		return RESULT_NON_EMPTY;
	}
}
