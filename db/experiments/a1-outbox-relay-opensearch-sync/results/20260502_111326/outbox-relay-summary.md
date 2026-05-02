# Outbox Relay OpenSearch Smoke Summary

- PostgreSQL target: docker compose postgres/readpath_lab
- OpenSearch URL: http://localhost:9200
- OpenSearch image: opensearchproject/opensearch:2.15.0
- Smoke index: products_search_relay_smoke_v1
- Write alias: products_search_relay_smoke_write
- Final smoke status: pass

| metric | value |
|---|---:|
| processed event count | 5 |
| pending event count | 0 |
| failed event count | 1 |
| retry count | 1 |
| relay batch duration ms | 13508 |
| idempotent replay mismatch count | 0 |
| duplicate replay count | 0 |
| status-change deleted document count | 0 |
| cleaned old DONE event count | 1 |
| retained FAILED cleanup count | 1 |
| retained recent DONE count | 1 |
| retained PENDING count | 1 |

Final document comparison result: pass

Status-change behavior: source status DELETED deletes the OpenSearch document.

This smoke result is not a benchmark or production readiness claim.
