# OpenSearch Lag Fallback Rollback Operations Smoke Summary

- PostgreSQL target: docker compose postgres/readpath_lab
- OpenSearch URL: http://localhost:9200
- OpenSearch image: opensearchproject/opensearch:2.15.0
- Smoke v1 index: products_search_ops_smoke_v1
- Smoke v2 index: products_search_ops_smoke_v2
- Read alias: products_search_ops_smoke_read
- Write alias: products_search_ops_smoke_write
- Current alias: products_search_ops_smoke_current
- Measurement started at: 2026-05-02T19:46:31.6245922+09:00
- Measurement finished at: 2026-05-02T19:46:39.7943996+09:00
- Final smoke status: pass

| metric | value |
|---|---:|
| p95 event lag seconds | 6.9359604 |
| p95 event lag threshold seconds | 30 |
| max event lag seconds | 7.189558 |
| max event lag threshold seconds | 60 |
| lag threshold result | pass |
| processed event count | 5 |
| failed event count | 0 |
| retry count | 0 |
| pending before recovery | 3 |
| pending after recovery | 0 |
| oldest pending age before recovery seconds | 2.531391 |
| oldest pending age after recovery seconds | 0 |
| fallback requirements defined | True |
| alias switch success | True |
| rollback success | True |
| rollback duration ms | 80 |
| previous index retained | True |
| reindex runbook documented | True |

These thresholds are local smoke validation gates, not production SLA/SLO.
Lag, duration, and rollback timing values are local smoke metrics only.
This smoke result is not a benchmark, production capacity claim, or production readiness claim.
