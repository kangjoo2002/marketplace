# Relay Instrumentation Smoke Summary

- Environment: local synthetic / junit relay instrumentation smoke
- Run id: `relay-instrumentation-smoke-junit-20260510`
- Event count: 100
- Claimed events: 100
- DONE events: 100
- FAILED events: 0
- Pending count: 0
- Processing count: 0
- Total processing time ms: 57
- Writer call count: 100
- Relay timing log line count: 100

## Total Indexing Lag Ms

| metric | value |
|---|---:|
| p50 | 115 |
| p95 | 129 |
| p99 | 131 |
| max | 131 |

## Breakdown

| metric | p50 | p95 | p99 | max |
|---|---:|---:|---:|---:|
| queueWaitMs | 74 | 74 | 74 | 74 |
| sourceDocumentLoadMs | 0 | 0 | 0 | 8 |
| openSearchWriteMs | 0 | 0 | 0 | 0 |
| outboxStateTransitionMs | 0 | 0 | 0 | 0 |
| relayProcessingMs | 0 | 0 | 0 | 9 |

## Notes

This is a relay instrumentation smoke measurement. It invokes `ProductSearchOutboxRelayService.processBatch()` directly and uses a counting writer instead of a real OpenSearch network call.

These CountingIndexWriter-based values validate relay timing instrumentation only and must not be used as the single-index OpenSearch baseline for Bulk comparison.

No Bulk Indexing, batch size tuning, retry/backoff change, circuit breaker change, OpenSearch mapping change, fallback behavior change, claim behavior change, scheduler delay change, k6 benchmark, production SLO/SLA claim, or invented numbers are included.
