# A-1 OpenSearch Circuit Breaker Hardening

## Purpose

This experiment hardens the feature-flagged product search OpenSearch read path
with a local circuit breaker.

It exists after the feature flag read-path switch because direct fallback handles
one OpenSearch failure, but repeated failures would otherwise keep sending API
requests to Search, waiting for timeout or connection failure, and then falling
back to PostgreSQL on every request.

PostgreSQL remains the source of truth. OpenSearch is a search read model. The
DB path remains the default read path.

## Scope

This task includes:

- circuit breaker state for the OpenSearch product search read path
- CLOSED, OPEN, and HALF_OPEN behavior
- immediate DB fallback while the breaker is OPEN
- short-circuit and half-open counters for local smoke artifacts
- validation that invalid client requests are not hidden by fallback
- validation that flag-off DB read path remains unaffected
- documentation and local smoke artifacts

This task explicitly excludes:

- k6 scripts, warm-up, or measured benchmark
- production-like load testing
- production monitoring or dashboarding
- production readiness claims
- production SLA/SLO definition
- backfill, relay, catch-up replay, mapping, or alias changes
- relevance scoring, synonyms, typo tolerance, or autocomplete
- Kafka, Debezium, CDC, or external resilience platforms

## Circuit Breaker States

| state | behavior |
|---|---|
| `CLOSED` | OpenSearch calls are allowed. Fallback-eligible OpenSearch failures increment consecutive failure count. |
| `OPEN` | OpenSearch calls are skipped. The API immediately uses DB fallback and increments short-circuit metrics. |
| `HALF_OPEN` | After the open wait duration elapses, a limited number of probe calls are allowed. Success closes the breaker; failure reopens it. |

## Configuration

| key | default |
|---|---:|
| `readpath.product-search.open-search.circuit-breaker.enabled` | `true` |
| `readpath.product-search.open-search.circuit-breaker.failure-threshold` | `3` |
| `readpath.product-search.open-search.circuit-breaker.open-wait-ms` | `1000` |
| `readpath.product-search.open-search.circuit-breaker.half-open-permitted-calls` | `1` |

Existing read-path defaults remain:

| key | default |
|---|---|
| `readpath.product-search.read-path` | `db` |
| `readpath.product-search.open-search.timeout-ms` | `500` |

## Read-path Integration

Logical flow:

```text
if readPath == db:
  use PostgreSQL product search directly

if readPath == opensearch:
  if circuit breaker is OPEN:
    record short-circuit fallback
    use PostgreSQL fallback immediately

  try OpenSearch product search
    on success:
      record circuit breaker success
      return Search response

    on fallback-eligible OpenSearch failure:
      record fallback and circuit breaker failure
      use PostgreSQL fallback

    on validation/client error:
      do not fallback
      do not count as OpenSearch infrastructure failure
      return the validation/client error
```

The circuit breaker protects only the OpenSearch read path. Flag-off DB reads do
not consult OpenSearch and are not affected by breaker state.

## Fallback Behavior

OPEN state fallback uses the same response shape as the existing DB fallback,
but records the reason as `CIRCUIT_OPEN`. This increments fallback and fallback
success counts without incrementing OpenSearch infrastructure failure count.

Fallback-eligible OpenSearch failures remain:

- timeout
- HTTP 5xx
- connection failure
- malformed Search response

Non-fallback conditions remain:

- request validation error
- unsupported query parameter
- client-side 4xx caused by invalid input

Invalid client requests must not open the breaker and must not trigger DB
fallback.

## Smoke Validation

Start local dependencies and run:

```powershell
.\db\experiments\a1-opensearch-circuit-breaker\scripts\run-opensearch-circuit-breaker-smoke.ps1
```

Optional overrides:

```powershell
$env:OPENSEARCH_URL = "http://localhost:9200"
$env:CIRCUIT_BREAKER_SMOKE_APP_PORT = "18081"
.\db\experiments\a1-opensearch-circuit-breaker\scripts\run-opensearch-circuit-breaker-smoke.ps1
```

The smoke uses controlled namespaced rows and an isolated index/alias:

```text
products_search_circuit_breaker_smoke_v1
products_search_circuit_breaker_smoke_read
```

## Expected Validation Result

| scenario | expected |
|---|---|
| closed state Search success | HTTP 200 from Search path, breaker remains closed, fallback count 0 |
| repeated OpenSearch failures | first failures DB fallback, breaker opens after threshold |
| open state short-circuit | OpenSearch skipped, HTTP 200 via DB fallback, short-circuit count increments |
| half-open recovery success | wait elapses, probe succeeds, breaker closes |
| half-open failure | wait elapses, probe fails, breaker reopens |
| non-fallback validation error | HTTP 400, no fallback, no breaker failure |
| flag off DB path | HTTP 200 via DB, no OpenSearch call |

## Generated Artifacts

Successful runs write under `results/<timestamp>/`:

```text
circuit-breaker-summary.md
circuit-breaker-metrics.json
closed-state-search-success-result.json
open-transition-short-circuit-result.json
half-open-recovery-success-result.json
half-open-failure-reopen-result.json
non-fallback-validation-result.json
flag-off-db-result.json
opensearch-smoke-index-result.json
prepare-result.json
```

Artifacts are written under `results/<timestamp>.partial` first. The directory
is renamed to `results/<timestamp>` only after all assertions pass. Failed runs
retain the partial directory with `FAILED_PARTIAL.txt`.

## Limitations

- Local smoke only.
- No k6 benchmark is run.
- No production monitoring is added.
- No production readiness claim is made.
- No production SLA/SLO is defined.
- The breaker is an in-process local state machine, suitable for this project
  smoke validation and feature-flagged read-path hardening.

## Next Step

OpenSearch API k6 benchmark.
