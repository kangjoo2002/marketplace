# OpenSearch Circuit Breaker Smoke Summary

- PostgreSQL target: docker compose postgres/readpath_lab
- OpenSearch URL: http://localhost:9200
- OpenSearch image: opensearchproject/opensearch:2.15.0
- Smoke index: products_search_circuit_breaker_smoke_v1
- Smoke read alias: products_search_circuit_breaker_smoke_read
- Read path flag: readpath.product-search.read-path
- Default read path: db
- Circuit breaker enabled: true
- Failure threshold: 3
- Open wait ms: 1000
- Half-open permitted calls: 1
- Timeout ms: 500
- Final smoke status: pass

| metric | value |
|---|---:|
| closed state Search success result | pass |
| open transition result | pass |
| short-circuit fallback result | pass |
| half-open recovery result | pass |
| half-open failure result | pass |
| non-fallback validation error result | pass |
| flag off DB path result | pass |
| fallback count | 8 |
| fallback success count | 8 |
| OpenSearch failure count | 6 |
| timeout count | 0 |
| circuit breaker open count | 4 |
| short-circuited request count | 2 |
| half-open attempt count | 2 |
| half-open success count | 1 |
| half-open failure count | 1 |

This smoke result is not a k6 benchmark, production readiness claim, or production SLA/SLO.
