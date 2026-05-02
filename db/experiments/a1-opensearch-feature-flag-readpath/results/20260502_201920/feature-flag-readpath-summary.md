# OpenSearch Feature Flag Read Path Smoke Summary

- PostgreSQL target: docker compose postgres/readpath_lab
- OpenSearch URL: http://localhost:9200
- OpenSearch image: opensearchproject/opensearch:2.15.0
- Smoke index: products_search_switch_smoke_v1
- Smoke read alias: products_search_switch_smoke_read
- Feature flag: readpath.product-search.read-path
- Default flag value: db
- Timeout ms: 500
- Circuit breaker implemented: false
- Final smoke status: pass

| metric | value |
|---|---:|
| DB path smoke result | pass |
| Search path smoke result | pass |
| fallback smoke result | pass |
| fallback count | 1 |
| fallback success count | 1 |
| timeout count | 0 |
| OpenSearch failure scenario count | 1 |
| non-fallback validation error result | pass |
| flag rollback pass | True |
| flag rollback time ms | 18435 |

OpenSearch HTTP 5xx and malformed Search response fallback scenarios are documented as manual/future smoke cases in this task.
Actual circuit breaker state management is excluded and remains a later hardening task.
This smoke result is not a k6 benchmark, production readiness claim, or production SLA/SLO.
