# A-1 OpenSearch Lag Fallback Rollback Operations Validation

## Purpose

This experiment validates local operational gates before any product search API
read-path switch to OpenSearch.

It comes after mapping/alias validation, transactional outbox capture, outbox
relay, checkpoint backfill, catch-up replay, and static DB/Search dual-run
verification.

PostgreSQL remains the source of truth. OpenSearch is a search read model.

## Scope

This task includes:

- local outbox-to-OpenSearch event lag measurement
- controlled pending/backlog observation and recovery
- local smoke lag threshold evaluation
- fallback requirement definition for a later API switch task
- isolated alias switch smoke
- isolated alias rollback smoke
- previous index retention verification
- reindex recovery runbook documentation

This task excludes:

- API read-path switch
- feature flag implementation
- DB fallback implementation in application code
- k6 benchmark or API benchmark
- production monitoring or dashboarding
- production retry or retention scheduler
- Kafka, Debezium, or CDC
- relevance, synonym, typo, or autocomplete work
- lag optimization
- production migration readiness

This is local operations smoke validation only.

## Local Lag Thresholds

| metric | local smoke gate |
|---|---:|
| p95 event lag | `<= 30 seconds` |
| max event lag | `<= 60 seconds` |
| pending event count after recovery | `0` |
| oldest pending age after recovery | `0 seconds` |
| failed event count after recovery | `0` |

These thresholds are local smoke validation gates, not production SLA/SLO.
They are not user-facing guarantees.

## Event Lag Calculation

Event lag is calculated from `search_outbox`:

```text
event lag = processed_at - created_at
```

Only namespaced events created by this experiment after PostgreSQL readiness and
OpenSearch health are established are included in normal p95/max event lag.

Controlled backlog fixture events are measured separately and are excluded from
normal p95/max event lag.

## Measurement Control

The smoke runner:

1. waits for PostgreSQL readiness
2. waits for OpenSearch health for up to 120 seconds
3. applies/verifies required local schemas
4. prepares namespaced source rows
5. creates lag measurement outbox events only after both services are ready
6. records `measurement_started_at`
7. records `measurement_finished_at`
8. writes artifacts under `results/<timestamp>.partial`
9. renames to `results/<timestamp>` only after all assertions pass

Docker container startup time and OpenSearch health wait time are not included
in event lag.

If readiness was not established before event creation, the artifact must not be
treated as official.

## Pending / Backlog Strategy

The controlled backlog scenario:

1. inserts separate namespaced `PENDING` outbox events
2. waits a short controlled local interval
3. records pending count and oldest pending age before recovery
4. runs relay processing
5. records pending count, oldest pending age, and failed count after recovery

This proves observability and recovery behavior for local smoke data. It is not
production lag.

## Fallback Requirements

This task defines fallback requirements only. It does not wire DB fallback into
application code.

Future API read-path switch fallback triggers:

- OpenSearch request timeout
- OpenSearch HTTP 5xx
- connection refused
- connection reset
- host unreachable
- DNS failure
- circuit breaker open
- malformed or invalid Search response

Non-fallback conditions:

- request validation error
- unsupported query parameter
- client-side 4xx caused by invalid input

A later API switch task should validate timeout, 5xx, connection refused,
circuit breaker, and invalid response scenarios while proving client-side input
errors do not fallback.

## Alias Switch And Rollback

The smoke uses isolated physical indexes:

```text
products_search_ops_smoke_v1
products_search_ops_smoke_v2
```

Smoke aliases:

```text
products_search_ops_smoke_read
products_search_ops_smoke_write
products_search_ops_smoke_current
```

The script creates both indexes with the selected nested mapping from:

```text
db/experiments/a1-opensearch-index-mapping-alias/mappings/products_v1_nested.json
```

The read/current aliases start on `v1`, switch to `v2`, then roll back to `v1`.
Rollback duration is recorded.

The write alias remains on `v1` during this operations smoke so that relay lag
documents are written to a stable smoke target while read/current alias movement
is validated independently.

## Previous Index Retention

For this local smoke, previous index retention means both isolated physical
indexes still exist after rollback. Production retention duration is not defined
in this task.

## Reindex Recovery Runbook

Runbook:

```text
runbooks/reindex-recovery-runbook.md
```

It documents new index creation, selected nested mapping application, backfill,
count validation, catch-up replay, DB/Search comparison, alias switch, rollback,
previous index retention, old index cleanup, and required pre-switch metrics.

## Validation Commands

Start PostgreSQL:

```powershell
docker compose up -d postgres
```

Start local OpenSearch smoke service:

```powershell
docker compose -f db\experiments\a1-opensearch-index-mapping-alias\docker-compose.opensearch-smoke.yml up -d
```

Run operations smoke:

```powershell
$env:OPENSEARCH_URL = "http://localhost:9200"
.\db\experiments\a1-opensearch-lag-fallback-rollback\scripts\run-opensearch-lag-fallback-rollback.ps1
```

Optional OpenSearch smoke teardown:

```powershell
docker compose -f db\experiments\a1-opensearch-index-mapping-alias\docker-compose.opensearch-smoke.yml down -v
```

## Expected Result

| metric | expected |
|---|---:|
| p95 event lag threshold result | pass |
| max event lag threshold result | pass |
| failed event count | 0 |
| retry count | 0 |
| pending event count after recovery | 0 |
| oldest pending age after recovery | 0 |
| failed event count after recovery | 0 |
| fallback requirements defined | yes |
| alias switch success | true |
| rollback success | true |
| previous index retained | true |
| reindex runbook documented | true |

## Generated Artifacts

Successful runs write:

```text
results/<timestamp>/ops-smoke-summary.md
results/<timestamp>/measurement-control-result.json
results/<timestamp>/lag-metrics-result.json
results/<timestamp>/backlog-recovery-result.json
results/<timestamp>/fallback-requirements-result.json
results/<timestamp>/alias-switch-result.json
results/<timestamp>/alias-rollback-result.json
results/<timestamp>/reindex-runbook-result.json
```

The script writes first to `results/<timestamp>.partial`. If validation fails,
the directory remains clearly marked with `FAILED_PARTIAL.txt` and must not be
treated as an official pass artifact.

## Limitations

- Local Docker Compose PostgreSQL and experiment-local OpenSearch only.
- Local smoke thresholds are not production SLA/SLO.
- No API read-path switch.
- No DB fallback implementation.
- No k6 benchmark.
- No production monitoring.
- No production readiness claim.
- This task measures and gates lag; it does not optimize lag.

## Next Step

Feature flag read-path switch.
