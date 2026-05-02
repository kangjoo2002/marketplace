# OpenSearch Catch-up Dual-run Smoke Summary

- PostgreSQL target: docker compose postgres/readpath_lab
- OpenSearch URL: http://localhost:9200
- OpenSearch image: opensearchproject/opensearch:2.15.0
- Smoke index: products_search_catchup_smoke_v1
- Read alias: products_search_catchup_smoke_read
- Write alias: products_search_catchup_smoke_write
- Dual-run mode: static_shadow_comparison
- Final smoke status: pass

| metric | value |
|---|---:|
| backfill start outbox id | 59 |
| replayed event count | 3 |
| replay duration ms | 8060 |
| pending after replay | 0 |
| failed after replay | 0 |
| compared query count | 3 |
| mismatch threshold ratio | 0 |
| mismatch count | 0 |
| mismatch ratio | 0 |
| top-k mismatch count | 0 |
| missing in search count | 0 |
| extra in search count | 0 |
| ordering mismatch count | 0 |
| sample diff count | 0 |
| stale by updated_at count | 0 |

Snapshot captured at: 2026-05-02T14:55:07.4857395+09:00

Search remains a shadow comparison target in this smoke. No API read-path switch is implemented.
This smoke result is not a benchmark or production migration readiness claim.
