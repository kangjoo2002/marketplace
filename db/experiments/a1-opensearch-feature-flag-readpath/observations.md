# A-1 OpenSearch Feature Flag Read Path Observations

## Current Status

Feature-flag read-path implementation and local smoke validation are complete.

Generated artifact path:

```text
db/experiments/a1-opensearch-feature-flag-readpath/results/20260502_201920
```

## Flag Source / Default

| item | value |
|---|---|
| flag name | `readpath.product-search.read-path` |
| flag source | Spring application property or environment override |
| default flag value | `db` |
| allowed values | `db`, `opensearch` |

## Smoke Results

| metric | value |
|---|---|
| DB path smoke result | pass |
| Search path smoke result | pass |
| fallback scenario result | pass |
| fallback count | 1 |
| fallback success count | 1 |
| timeout count | 0 |
| OpenSearch failure scenario count | 1 |
| non-fallback validation error result | pass |
| flag rollback result | pass |
| flag rollback time | 18435 ms |

The fallback scenario used `readpath.product-search.read-path=opensearch` with
`readpath.product-search.open-search.base-url=http://127.0.0.1:1`. The API
returned HTTP 200 from the DB fallback path and preserved the existing response
shape.

The non-fallback validation scenario used an invalid `sort=ratingDesc` request
and returned HTTP 400 without fallback.

## Circuit Breaker

Circuit breaker implemented: false.

Circuit breaker follow-up documented: true.

## Limitations

- This task does not implement a circuit breaker.
- OpenSearch HTTP 5xx and malformed Search response fallback paths are
  implemented in the adapter classification, but deterministic local fake
  server smoke scenarios are documented as manual/future validation.
- This task does not run k6.
- This task does not claim production readiness.
- This task does not define production SLA/SLO.

## Next Step

OpenSearch circuit breaker hardening.
