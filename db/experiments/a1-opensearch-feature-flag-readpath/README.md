# A-1 OpenSearch Feature Flag Read Path

## Purpose

This experiment connects the product search API read path to OpenSearch behind a
feature flag while keeping the PostgreSQL DB path as the default.

It comes after the lag/fallback/rollback operations validation because this
task depends on the documented gates for lag, direct OpenSearch failures,
fallback, alias switch, and rollback.

PostgreSQL remains the source of truth. OpenSearch is a search read model.

## Scope

This task includes:

- feature-flagged DB/OpenSearch read-path selection
- OpenSearch product search read adapter
- DB fallback for direct OpenSearch failures
- fallback logging and local smoke artifact counts
- flag rollback smoke back to DB path
- documentation and smoke artifacts

This task excludes:

- circuit breaker closed/open/half-open state
- circuit breaker failure-rate windows
- half-open probes
- circuit breaker metrics or library integration
- k6 benchmark
- production traffic switch
- production monitoring or dashboarding
- backfill, relay, or catch-up changes
- Kafka, Debezium, or CDC
- relevance, synonym, typo, or autocomplete work

Actual circuit breaker implementation is a later hardening task.

## Feature Flag

| item | value |
|---|---|
| flag name | `readpath.product-search.read-path` |
| source | Spring application property or environment override |
| default | `db` |
| allowed values | `db`, `opensearch` |

Enable Search path:

```powershell
.\gradlew.bat bootRun --args="--readpath.product-search.read-path=opensearch"
```

Rollback to DB path:

```powershell
.\gradlew.bat bootRun --args="--readpath.product-search.read-path=db"
```

No external feature flag service is added.

## Read-path Routing

Logical flow:

```text
if readPath == db:
  use existing PostgreSQL product search

if readPath == opensearch:
  try OpenSearch product search
  if the OpenSearch failure is fallback-eligible:
    log fallback
    use existing PostgreSQL product search
  otherwise:
    preserve validation/client error behavior
```

The existing DB query path is retained.

## OpenSearch Adapter Strategy

The adapter uses the selected document contract:

- `productId`
- `sellerId`
- `categoryId`
- `brandId`
- `status`
- `price`
- `rating`
- `reviewCount`
- `createdAt`
- `updatedAt`
- `options[].color`
- `options[].size`
- `options[].stockStatus`

Option filters are emitted as one `nested` query under `path: "options"` so
`color`, `size`, and `stockStatus` preserve same-option-row semantics.

The adapter supports the existing exact-filter and sort-oriented API shape. It
does not add relevance, typo tolerance, synonym search, autocomplete, or mapping
changes.

## Fallback Rules

Implemented fallback-eligible direct OpenSearch failures:

- request timeout
- OpenSearch HTTP 5xx
- connection refused/reset/unreachable style connection failure
- malformed or invalid Search response

Documented future fallback trigger:

- circuit breaker open

Circuit breaker state management is not implemented in this task.

Non-fallback conditions:

- request validation error
- unsupported query parameter
- client-side 4xx caused by invalid input

Invalid client requests must not be hidden by DB fallback.

## Timeout Policy

Config:

```text
readpath.product-search.open-search.timeout-ms=500
```

This timeout is a local fallback smoke setting. It is not a production latency
SLA/SLO.

## Smoke Validation

Start PostgreSQL:

```powershell
docker compose up -d postgres
```

Start local OpenSearch smoke service:

```powershell
docker compose -f db\experiments\a1-opensearch-index-mapping-alias\docker-compose.opensearch-smoke.yml up -d
```

Run feature-flag read-path smoke:

```powershell
$env:OPENSEARCH_URL = "http://localhost:9200"
.\db\experiments\a1-opensearch-feature-flag-readpath\scripts\run-opensearch-feature-flag-readpath-smoke.ps1
```

The smoke prepares a small `products` + `product_options_moderate_skew` fixture
and an isolated OpenSearch index/alias:

```text
products_search_switch_smoke_v1
products_search_switch_smoke_read
```

## Expected Validation Result

| scenario | expected |
|---|---|
| flag off DB path | HTTP 200, existing API shape, fallback count 0 |
| flag on Search path | HTTP 200, existing API shape, fallback count 0 |
| OpenSearch unavailable fallback | HTTP 200 via DB fallback, fallback count increments |
| non-fallback validation error | HTTP 400, fallback not triggered |
| flag rollback | DB path HTTP 200, rollback time recorded |

OpenSearch HTTP 5xx and malformed Search response fallback are implemented in
the adapter and documented as manual/future smoke scenarios because this local
script does not start a deterministic fake OpenSearch server.

## Generated Artifacts

Successful runs write:

```text
results/<timestamp>/feature-flag-readpath-summary.md
results/<timestamp>/feature-flag-readpath-metrics.json
results/<timestamp>/db-path-smoke-result.json
results/<timestamp>/search-path-smoke-result.json
results/<timestamp>/fallback-smoke-result.json
results/<timestamp>/non-fallback-validation-result.json
results/<timestamp>/flag-rollback-result.json
results/<timestamp>/opensearch-smoke-index-result.json
results/<timestamp>/manual-future-failure-scenarios.json
```

Artifacts are written under `results/<timestamp>.partial` first. The directory
is renamed to `results/<timestamp>` only after all assertions pass.

## Limitations

- Local smoke only.
- No k6 benchmark.
- No production readiness claim.
- No production SLA/SLO.
- No actual circuit breaker implementation.
- No production monitoring.

## Next Step

OpenSearch circuit breaker hardening.
