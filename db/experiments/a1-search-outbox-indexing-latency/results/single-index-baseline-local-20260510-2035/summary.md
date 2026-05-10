# Single-Document Indexing Baseline Summary

- Environment: local synthetic / local PostgreSQL + OpenSearch smoke
- Run id: single-index-baseline-local-20260510-2035
- Event count: 100
- Claimed events: 100
- DONE events: 100
- FAILED events: 0
- Pending count: 0
- Processing count: 0
- Total processing time ms: 32806
- OpenSearch write/delete call count: 100
- Relay timing log line count: 100
- OpenSearch index: products_search_single_index_baseline_202605102035
- OpenSearch write alias: products_search_single_index_baseline_write

## Total Indexing Lag Ms

| metric | value |
|---|---:|
| p50 | 16805.131 |
| p95 | 31172.09755 |
| p99 | 32508.988720000005 |
| max | 32816.4550000 |

## Breakdown

| metric | p50 | p95 | p99 | max |
|---|---:|---:|---:|---:|
| queueWaitMs | 13408 | 26453 | 26453 | 26453 |
| sourceDocumentLoadMs | 122 | 174 | 205 | 231 |
| openSearchWriteMs | 58 | 74 | 101 | 118 |
| outboxStateTransitionMs | 126 | 168 | 200 | 214 |
| relayProcessingMs | 310 | 382 | 394 | 417 |

## Notes

This is a local synthetic PostgreSQL + OpenSearch smoke measurement. It uses one OpenSearch document write per claimed outbox event. It is not Bulk Indexing, a k6 benchmark, or a production SLO/SLA claim.
