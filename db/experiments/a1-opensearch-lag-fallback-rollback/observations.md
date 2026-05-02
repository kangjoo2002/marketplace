# A-1 OpenSearch Lag Fallback Rollback Observations

## Current Status

Local PostgreSQL + OpenSearch lag/fallback/rollback operations smoke validation
passed.

Generated artifact path:

```text
db/experiments/a1-opensearch-lag-fallback-rollback/results/20260502_194815/
```

## Measurement Control Result

Pass.

Observed:

| control | value |
|---|---|
| PostgreSQL ready before event creation | true |
| OpenSearch healthy before event creation | true |
| event creation started after readiness | true |
| Docker startup time included in event lag | false |
| OpenSearch health wait included in event lag | false |
| normal lag separated from backlog recovery | true |
| controlled backlog excluded from normal lag metrics | true |
| measurement_started_at | `2026-05-02T19:48:20.5508183+09:00` |
| measurement_finished_at | `2026-05-02T19:48:29.4915074+09:00` |

PostgreSQL readiness output:

```text
/var/run/postgresql:5432 - accepting connections
```

OpenSearch health was green.

## Lag Metric Result

Pass.

| metric | value |
|---|---:|
| p95 event lag seconds | 7.6081268 |
| p95 event lag threshold seconds | 30 |
| max event lag seconds | 7.929331 |
| max event lag threshold seconds | 60 |
| lag threshold result | pass |
| processed event count | 5 |
| failed event count | 0 |
| retry count | 0 |

Event lag is measured as `processed_at - created_at` for namespaced normal
smoke events only.

## Backlog Recovery Result

Pass.

| metric | value |
|---|---:|
| pending event count before recovery | 3 |
| pending event count after recovery | 0 |
| pending event count threshold after recovery | 0 |
| oldest pending age seconds before recovery | 2.438107 |
| oldest pending age seconds after recovery | 0 |
| oldest pending age threshold seconds after recovery | 0 |
| failed event count after recovery | 0 |
| processed backlog event count | 3 |

Controlled backlog events were excluded from normal p95/max event lag.

## Fallback Requirement Result

Pass.

| requirement | value |
|---|---|
| fallback requirement defined | true |
| OpenSearch timeout scenario defined | true |
| OpenSearch 5xx scenario defined | true |
| connection refused scenario defined | true |
| connection reset scenario defined | true |
| host unreachable scenario defined | true |
| DNS failure scenario defined | true |
| circuit breaker scenario defined | true |
| invalid Search response scenario defined | true |
| non-fallback client error conditions defined | true |
| application fallback implemented in this task | false |

Fallback is documented only. No DB fallback code was added.

## Alias Switch Result

Pass.

| metric | value |
|---|---|
| v1 index | `products_search_ops_smoke_v1` |
| v2 index | `products_search_ops_smoke_v2` |
| read alias | `products_search_ops_smoke_read` |
| write alias | `products_search_ops_smoke_write` |
| current alias | `products_search_ops_smoke_current` |
| initial read alias sees v1 marker | true |
| read alias sees v2 marker after switch | true |
| read alias still sees v1 marker after switch | false |
| alias switch success | true |

The write alias stayed on `v1` during this operations smoke so relay lag writes
had a stable target while read/current alias movement was validated
independently.

## Rollback Result

Pass.

| metric | value |
|---|---:|
| rollback success | true |
| rollback duration ms | 95 |
| read alias sees v1 marker after rollback | true |
| read alias still sees v2 marker after rollback | false |
| previous index retained | true |

Retained smoke indexes:

```text
products_search_ops_smoke_v1
products_search_ops_smoke_v2
```

## Reindex Runbook Result

Pass.

| check | value |
|---|---|
| reindex runbook documented | true |
| previous index retention policy documented | true |

Runbook:

```text
db/experiments/a1-opensearch-lag-fallback-rollback/runbooks/reindex-recovery-runbook.md
```

## Artifact Files

```text
results/20260502_194815/ops-smoke-summary.md
results/20260502_194815/measurement-control-result.json
results/20260502_194815/lag-metrics-result.json
results/20260502_194815/backlog-recovery-result.json
results/20260502_194815/fallback-requirements-result.json
results/20260502_194815/alias-switch-result.json
results/20260502_194815/alias-rollback-result.json
results/20260502_194815/reindex-runbook-result.json
```

## Commands Run

```powershell
docker compose up -d postgres
docker compose -f db\experiments\a1-opensearch-index-mapping-alias\docker-compose.opensearch-smoke.yml up -d
$env:OPENSEARCH_URL='http://localhost:9200'
.\db\experiments\a1-opensearch-lag-fallback-rollback\scripts\run-opensearch-lag-fallback-rollback.ps1
```

## Limitations

- This is local operations smoke validation only.
- Thresholds are local smoke validation gates, not production SLA/SLO.
- Lag, duration, and rollback timing values are local smoke metrics only.
- No API read-path switch is implemented.
- No feature flag is implemented.
- No DB fallback code is implemented.
- No k6 benchmark is added or run.
- No production monitoring or production readiness claim is made.

## Next Step

Feature flag read-path switch.
