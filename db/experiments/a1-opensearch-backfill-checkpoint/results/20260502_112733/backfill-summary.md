# OpenSearch Backfill Checkpoint Smoke Summary

- PostgreSQL target: docker compose postgres/readpath_lab
- OpenSearch URL: http://localhost:9200
- OpenSearch image: opensearchproject/opensearch:2.15.0
- Smoke index: products_search_backfill_smoke_v1
- Write alias: products_search_backfill_smoke_write
- Source filter: products.id BETWEEN -19002999 AND -19002000
- Final smoke status: pass

| metric | value |
|---|---:|
| backfill start outbox id | 59 |
| source product count | 4 |
| indexed document count | 4 |
| missing document count | 0 |
| extra document count | 0 |
| sample document comparison count | 3 |
| sample document mismatch count | 0 |
| backfill duration ms | 8027 |
| backfill throughput products/sec | 0.498 |
| failed batch count | 0 |
| retried batch count | 0 |
| checkpoint position after interruption | -19002003 |
| final checkpoint position | -19002001 |
| resume success | True |

This smoke result is not a benchmark or production migration readiness claim.
