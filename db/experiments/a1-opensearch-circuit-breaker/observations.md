# A-1 OpenSearch Circuit Breaker Observations

## Current Status

Implementation added. Targeted unit/controller tests passed with an isolated
Gradle cache. Local HTTP smoke passed and generated artifacts at:

```text
db/experiments/a1-opensearch-circuit-breaker/results/20260502_210700/
```

## Circuit Breaker Config

| item | value |
|---|---:|
| enabled | `true` |
| failure threshold | `3` |
| open wait duration | `1000 ms` |
| half-open permitted calls | `1` |
| DB read path default | `db` |

## Validation Results

| scenario | result |
|---|---|
| closed state Search success | pass |
| repeated failure opens breaker | pass |
| open state short-circuit fallback | pass |
| half-open recovery success | pass |
| half-open failure reopens breaker | pass |
| non-fallback validation/client error | pass |
| flag off DB path unaffected | pass |

## Smoke Metrics

| metric | observed |
|---|---:|
| fallback count | `8` |
| fallback success count | `8` |
| OpenSearch failure count | `6` |
| timeout count | `0` |
| circuit breaker open count | `4` |
| short-circuited request count | `2` |
| half-open attempt count | `2` |
| half-open success count | `1` |
| half-open failure count | `1` |

## Commands Run

```powershell
git status --short
git branch --show-current
git pull --ff-only
git switch -c feat/opensearch-circuit-breaker
.\gradlew.bat test --tests "com.portfolio.readpath_lab.product.application.ProductSearchServiceTest" --tests "com.portfolio.readpath_lab.product.api.ProductSearchControllerTest"
.\gradlew.bat --no-daemon --max-workers=1 test --tests "com.portfolio.readpath_lab.product.application.ProductSearchServiceTest" --tests "com.portfolio.readpath_lab.product.api.ProductSearchControllerTest"
.\gradlew.bat --no-daemon --max-workers=1 cleanTest test --tests "com.portfolio.readpath_lab.product.application.ProductSearchServiceTest" --stacktrace
$env:GRADLE_USER_HOME = Join-Path (Get-Location) '.gradle-home'; .\gradlew.bat --no-daemon --max-workers=1 cleanTest test --tests "com.portfolio.readpath_lab.product.application.ProductSearchServiceTest" --tests "com.portfolio.readpath_lab.product.api.ProductSearchControllerTest"
$env:GRADLE_USER_HOME = 'C:\gradle-cache\readpath-lab-circuit-breaker'; .\gradlew.bat --no-daemon --max-workers=1 cleanTest test --tests "com.portfolio.readpath_lab.product.application.ProductSearchServiceTest" --tests "com.portfolio.readpath_lab.product.api.ProductSearchControllerTest"
.\db\experiments\a1-opensearch-circuit-breaker\scripts\run-opensearch-circuit-breaker-smoke.ps1
```

The first three Gradle test attempts failed before executing tests because the
existing Gradle cache could not start `GradleWorkerMain`. The isolated
repo-local Gradle cache run passed. The smoke script uses
`C:\gradle-cache\readpath-lab-circuit-breaker` so generated Gradle cache files
are not written into the repository. The final targeted test run with that
external cache passed.

## Smoke Artifacts

HTTP smoke artifacts:

```text
db/experiments/a1-opensearch-circuit-breaker/results/20260502_210700/
```

Required artifact policy:

- write to `results/<timestamp>.partial`
- rename to `results/<timestamp>` only after all checks pass
- retain failed partial artifacts with `FAILED_PARTIAL.txt`

## Limitations

- This is not a k6 benchmark.
- This is not production readiness.
- This does not define a production SLA/SLO.
- No production monitoring/dashboarding was added.
- No backfill, relay, catch-up replay, mapping, Kafka, Debezium, or CDC changes
  were made.

## Next Step

OpenSearch API k6 benchmark.
