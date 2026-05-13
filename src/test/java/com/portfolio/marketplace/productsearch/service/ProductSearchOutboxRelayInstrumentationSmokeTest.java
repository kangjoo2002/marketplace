package com.portfolio.marketplace.productsearch.service;

import com.portfolio.marketplace.productsearch.config.ProductSearchIndexingProperties;
import com.portfolio.marketplace.productsearch.domain.ProductSearchDocument;
import com.portfolio.marketplace.productsearch.domain.SearchOutboxEvent;
import com.portfolio.marketplace.productsearch.repository.ProductSearchDocumentRepository;
import com.portfolio.marketplace.productsearch.repository.SearchOutboxClaimDao;
import com.portfolio.marketplace.productsearch.repository.SearchOutboxJpaRepository;
import com.portfolio.marketplace.productsearch.repository.SearchOutboxStore;
import com.portfolio.marketplace.productsearch.service.port.ProductSearchIndexWriter;
import io.micrometer.core.instrument.simple.SimpleMeterRegistry;
import java.io.IOException;
import java.math.BigDecimal;
import java.nio.file.Files;
import java.nio.file.Path;
import java.time.Clock;
import java.time.Instant;
import java.time.LocalDateTime;
import java.time.OffsetDateTime;
import java.time.ZoneOffset;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.List;
import java.util.Locale;
import java.util.Optional;
import java.util.UUID;
import java.util.regex.Matcher;
import java.util.regex.Pattern;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.springframework.boot.test.system.CapturedOutput;
import org.springframework.boot.test.system.OutputCaptureExtension;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.Mockito.mock;

@ExtendWith(OutputCaptureExtension.class)
class ProductSearchOutboxRelayInstrumentationSmokeTest {

	private static final int EVENT_COUNT = 100;
	private static final Pattern TIMING_PATTERN = Pattern.compile(
			"queueWaitMs=(\\d+) sourceDocumentLoadMs=(\\d+) openSearchWriteMs=(\\d+) "
					+ "outboxStateTransitionMs=(\\d+) relayProcessingMs=(\\d+)"
	);

	@Test
	void measuresSingleDocumentIndexingBaseline(CapturedOutput output) throws IOException {
		String runId = runId();
		MeasuredSearchOutboxStore outboxStore = new MeasuredSearchOutboxStore(runId, EVENT_COUNT);
		ProductSearchDocumentRepository documentRepository = mock(ProductSearchDocumentRepository.class);
		CountingIndexWriter indexWriter = new CountingIndexWriter();
		ProductSearchIndexingProperties properties = new ProductSearchIndexingProperties();
		properties.getRelay().setBatchSize(EVENT_COUNT);
		ProductSearchOutboxRelayService relayService = new ProductSearchOutboxRelayService(
				outboxStore,
				documentRepository,
				indexWriter,
				properties,
				Clock.fixed(Instant.parse("2026-05-10T11:00:00Z"), ZoneOffset.UTC),
				new SimpleMeterRegistry()
		);
		org.mockito.Mockito.when(documentRepository.findByProductId(org.mockito.ArgumentMatchers.anyLong()))
				.thenAnswer(invocation -> Optional.of(document(invocation.getArgument(0))));

		long startedAt = System.nanoTime();
		int claimed = relayService.processBatch();
		long totalProcessingTimeMs = (System.nanoTime() - startedAt) / 1_000_000;

		List<TimingSample> timingSamples = timingSamples(output.getOut());
		BaselineSummary summary = new BaselineSummary(
				runId,
				EVENT_COUNT,
				claimed,
				outboxStore.doneCount(),
				outboxStore.failedCount(),
				outboxStore.pendingCount(),
				outboxStore.processingCount(),
				totalProcessingTimeMs,
				percentiles(outboxStore.totalIndexingLagMs()),
				percentiles(timingSamples.stream().map(TimingSample::queueWaitMs).toList()),
				percentiles(timingSamples.stream().map(TimingSample::sourceDocumentLoadMs).toList()),
				percentiles(timingSamples.stream().map(TimingSample::openSearchWriteMs).toList()),
				percentiles(timingSamples.stream().map(TimingSample::outboxStateTransitionMs).toList()),
				percentiles(timingSamples.stream().map(TimingSample::relayProcessingMs).toList()),
				indexWriter.callCount(),
				timingSamples.size()
		);

		assertThat(claimed).isEqualTo(EVENT_COUNT);
		assertThat(outboxStore.doneCount()).isEqualTo(EVENT_COUNT);
		assertThat(outboxStore.failedCount()).isZero();
		assertThat(outboxStore.pendingCount()).isZero();
		assertThat(indexWriter.callCount()).isEqualTo(EVENT_COUNT);
		assertThat(timingSamples).hasSize(EVENT_COUNT);

		writeArtifactsIfRequested(summary, output.getOut());
	}

	private static ProductSearchDocument document(long productId) {
		return new ProductSearchDocument(
				productId,
				20L,
				30L,
				40L,
				"ACTIVE",
				10000,
				BigDecimal.valueOf(4.55),
				12,
				LocalDateTime.parse("2026-05-10T10:00:00"),
				LocalDateTime.parse("2026-05-10T10:00:01"),
				LocalDateTime.parse("2026-05-10T10:00:01"),
				null,
				List.of()
		);
	}

	private static List<TimingSample> timingSamples(String output) {
		return output.lines()
				.filter(line -> line.contains("product_search_outbox_indexing_latency"))
				.map(TIMING_PATTERN::matcher)
				.filter(Matcher::find)
				.map(matcher -> new TimingSample(
						Long.parseLong(matcher.group(1)),
						Long.parseLong(matcher.group(2)),
						Long.parseLong(matcher.group(3)),
						Long.parseLong(matcher.group(4)),
						Long.parseLong(matcher.group(5))
				))
				.toList();
	}

	private static Percentiles percentiles(List<Long> values) {
		if (values.isEmpty()) {
			return new Percentiles(0, 0, 0, 0);
		}
		List<Long> sorted = values.stream().sorted().toList();
		return new Percentiles(
				percentile(sorted, 0.50),
				percentile(sorted, 0.95),
				percentile(sorted, 0.99),
				sorted.get(sorted.size() - 1)
		);
	}

	private static long percentile(List<Long> sorted, double percentile) {
		int index = (int) Math.ceil(percentile * sorted.size()) - 1;
		return sorted.get(Math.max(0, Math.min(index, sorted.size() - 1)));
	}

	private static void writeArtifactsIfRequested(BaselineSummary summary, String output) throws IOException {
		String resultDir = System.getenv("SEARCH_OUTBOX_BASELINE_RESULT_DIR");
		if (resultDir == null || resultDir.isBlank()) {
			return;
		}
		Path directory = Path.of(resultDir);
		Files.createDirectories(directory);
		Files.writeString(directory.resolve("indexing-lag-summary.json"), summary.toJson());
		Files.writeString(directory.resolve("relay-log-sample.txt"), relayLogSample(output));
		Files.writeString(directory.resolve("summary.md"), summary.toMarkdown());
	}

	private static String runId() {
		String resultDir = System.getenv("SEARCH_OUTBOX_BASELINE_RESULT_DIR");
		if (resultDir == null || resultDir.isBlank()) {
			return "relay-instrumentation-smoke-test";
		}
		return Path.of(resultDir).getFileName().toString();
	}

	private static String relayLogSample(String output) {
		return String.join(
				System.lineSeparator(),
				output.lines()
						.filter(line -> line.contains("product_search_outbox_indexing_latency"))
						.limit(20)
						.toList()
		) + System.lineSeparator();
	}

	private static class MeasuredSearchOutboxStore extends SearchOutboxStore {

		private final String runId;
		private final List<SearchOutboxEvent> pendingEvents;
		private final List<Long> totalIndexingLagMs = new ArrayList<>();
		private int doneCount;
		private int failedCount;
		private boolean claimed;

		private MeasuredSearchOutboxStore(String runId, int eventCount) {
			super(mock(SearchOutboxClaimDao.class), mock(SearchOutboxJpaRepository.class));
			this.runId = runId;
			this.pendingEvents = new ArrayList<>();
			OffsetDateTime createdAt = OffsetDateTime.now(ZoneOffset.UTC);
			for (int i = 1; i <= eventCount; i++) {
				pendingEvents.add(event(i, createdAt));
			}
		}

		@Override
		public List<SearchOutboxEvent> claimPendingProductEvents(
				int batchSize,
				long processingTimeoutMs,
				String relayInstanceId
		) {
			if (claimed) {
				return List.of();
			}
			claimed = true;
			OffsetDateTime claimedAt = OffsetDateTime.now(ZoneOffset.UTC);
			return pendingEvents.stream()
					.limit(batchSize)
					.map(event -> new SearchOutboxEvent(
							event.id(),
							event.aggregateId(),
							event.eventType(),
							event.schemaVersion(),
							event.payload(),
							event.retryCount(),
							event.claimToken(),
							event.createdAt(),
							claimedAt
					))
					.toList();
		}

		@Override
		public void markDone(SearchOutboxEvent event) {
			doneCount++;
			totalIndexingLagMs.add(Math.max(0, java.time.Duration.between(
					event.createdAt(),
					OffsetDateTime.now(ZoneOffset.UTC)
			).toMillis()));
		}

		@Override
		public void markFailed(SearchOutboxEvent event, String lastError) {
			failedCount++;
		}

		@Override
		public void markPendingRetry(SearchOutboxEvent event, String lastError, LocalDateTime nextRetryAt) {
			failedCount++;
		}

		private int doneCount() {
			return doneCount;
		}

		private int failedCount() {
			return failedCount;
		}

		private int pendingCount() {
			return pendingEvents.size() - doneCount - failedCount;
		}

		private int processingCount() {
			return 0;
		}

		private List<Long> totalIndexingLagMs() {
			return totalIndexingLagMs;
		}

		private SearchOutboxEvent event(int index, OffsetDateTime createdAt) {
			long productId = -33000000L - index;
			return new SearchOutboxEvent(
					index,
					productId,
					"PRODUCT_UPDATED",
					1,
					"{\"smokeRun\":\"" + runId + "\",\"productId\":" + productId + "}",
					0,
					UUID.nameUUIDFromBytes((runId + "-" + index).getBytes()).toString(),
					createdAt,
					null
			);
		}
	}

	private static class CountingIndexWriter implements ProductSearchIndexWriter {

		private int upsertCount;
		private int deleteCount;

		@Override
		public void upsert(ProductSearchDocument document) {
			upsertCount++;
		}

		@Override
		public void deleteByProductId(long productId) {
			deleteCount++;
		}

		private int callCount() {
			return upsertCount + deleteCount;
		}
	}

	private record TimingSample(
			long queueWaitMs,
			long sourceDocumentLoadMs,
			long openSearchWriteMs,
			long outboxStateTransitionMs,
			long relayProcessingMs
	) {
	}

	private record Percentiles(long p50, long p95, long p99, long max) {

		private String toJson() {
			return String.format(
					Locale.ROOT,
					"{\"p50\":%d,\"p95\":%d,\"p99\":%d,\"max\":%d}",
					p50,
					p95,
					p99,
					max
			);
		}
	}

	private record BaselineSummary(
			String runId,
			int eventCount,
			int claimedEvents,
			int doneEvents,
			int failedEvents,
			int pendingCount,
			int processingCount,
			long totalProcessingTimeMs,
			Percentiles totalIndexingLagMs,
			Percentiles queueWaitMs,
			Percentiles sourceDocumentLoadMs,
			Percentiles openSearchWriteMs,
			Percentiles outboxStateTransitionMs,
			Percentiles relayProcessingMs,
			int openSearchWriteDeleteCallCount,
			int relayTimingLogLineCount
	) {

		private String toJson() {
			return """
					{
					  "runId": "%s",
					  "environment": "local synthetic / junit smoke",
					  "eventCount": %d,
					  "claimedEvents": %d,
					  "doneEvents": %d,
					  "failedEvents": %d,
					  "pendingCount": %d,
					  "processingCount": %d,
					  "totalProcessingTimeMs": %d,
					  "totalIndexingLagMs": %s,
					  "breakdown": {
					    "queueWaitMs": %s,
					    "sourceDocumentLoadMs": %s,
					    "openSearchWriteMs": %s,
					    "outboxStateTransitionMs": %s,
					    "relayProcessingMs": %s
					  },
					  "openSearchWriteDeleteCallCount": %d,
					  "relayTimingLogLineCount": %d
					}
					""".formatted(
					runId,
					eventCount,
					claimedEvents,
					doneEvents,
					failedEvents,
					pendingCount,
					processingCount,
					totalProcessingTimeMs,
					totalIndexingLagMs.toJson(),
					queueWaitMs.toJson(),
					sourceDocumentLoadMs.toJson(),
					openSearchWriteMs.toJson(),
					outboxStateTransitionMs.toJson(),
					relayProcessingMs.toJson(),
					openSearchWriteDeleteCallCount,
					relayTimingLogLineCount
			);
		}

		private String toMarkdown() {
			return """
					# Single-Document Indexing Baseline Summary

					- Environment: local synthetic / junit smoke
					- Run id: `%s`
					- Event count: %d
					- Claimed events: %d
					- DONE events: %d
					- FAILED events: %d
					- Pending count: %d
					- Processing count: %d
					- Total processing time ms: %d
					- OpenSearch write/delete call count: %d
					- Relay timing log line count: %d

					## Total Indexing Lag Ms

					| metric | value |
					|---|---:|
					| p50 | %d |
					| p95 | %d |
					| p99 | %d |
					| max | %d |

					## Breakdown

					| metric | p50 | p95 | p99 | max |
					|---|---:|---:|---:|---:|
					| queueWaitMs | %d | %d | %d | %d |
					| sourceDocumentLoadMs | %d | %d | %d | %d |
					| openSearchWriteMs | %d | %d | %d | %d |
					| outboxStateTransitionMs | %d | %d | %d | %d |
					| relayProcessingMs | %d | %d | %d | %d |

					## Notes

					This is a local synthetic JUnit smoke measurement. It invokes `ProductSearchOutboxRelayService.processBatch()` directly and uses a counting writer instead of a real OpenSearch network call.

					No Bulk Indexing, batch size tuning, retry/backoff change, circuit breaker change, OpenSearch mapping change, fallback behavior change, claim behavior change, scheduler delay change, k6 benchmark, production SLO/SLA claim, or invented numbers are included.
					""".formatted(
					runId,
					eventCount,
					claimedEvents,
					doneEvents,
					failedEvents,
					pendingCount,
					processingCount,
					totalProcessingTimeMs,
					openSearchWriteDeleteCallCount,
					relayTimingLogLineCount,
					totalIndexingLagMs.p50,
					totalIndexingLagMs.p95,
					totalIndexingLagMs.p99,
					totalIndexingLagMs.max,
					queueWaitMs.p50,
					queueWaitMs.p95,
					queueWaitMs.p99,
					queueWaitMs.max,
					sourceDocumentLoadMs.p50,
					sourceDocumentLoadMs.p95,
					sourceDocumentLoadMs.p99,
					sourceDocumentLoadMs.max,
					openSearchWriteMs.p50,
					openSearchWriteMs.p95,
					openSearchWriteMs.p99,
					openSearchWriteMs.max,
					outboxStateTransitionMs.p50,
					outboxStateTransitionMs.p95,
					outboxStateTransitionMs.p99,
					outboxStateTransitionMs.max,
					relayProcessingMs.p50,
					relayProcessingMs.p95,
					relayProcessingMs.p99,
					relayProcessingMs.max
			);
		}
	}
}
