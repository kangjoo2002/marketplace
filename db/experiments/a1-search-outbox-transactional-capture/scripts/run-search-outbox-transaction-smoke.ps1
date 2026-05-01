$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$experimentDir = Resolve-Path (Join-Path $scriptDir "..")
$repoRoot = Resolve-Path (Join-Path $experimentDir "..\..\..")
$schemaPath = Join-Path $repoRoot "db\init\002_create_search_outbox.sql"
$smokeSqlPath = Join-Path $experimentDir "sql\search-outbox-transaction-smoke.sql"
$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$resultsRoot = Join-Path $experimentDir "results"
$resultDir = Join-Path $resultsRoot $timestamp

function Invoke-Psql {
    param(
        [Parameter(Mandatory = $true)]
        [string] $SqlPath,
        [switch] $TuplesOnly
    )

    $arguments = @(
        "compose",
        "exec",
        "-T",
        "postgres",
        "psql",
        "-U",
        "readpath",
        "-d",
        "readpath_lab",
        "-v",
        "ON_ERROR_STOP=1",
        "-q"
    )

    if ($TuplesOnly) {
        $arguments += @("-t", "-A")
    }

    $output = Get-Content -Raw $SqlPath | docker @arguments
    if ($LASTEXITCODE -ne 0) {
        throw "psql failed for $SqlPath with exit code $LASTEXITCODE"
    }

    return ($output -join "`n").Trim()
}

function Write-JsonFile {
    param(
        [Parameter(Mandatory = $true)]
        [object] $Value,
        [Parameter(Mandatory = $true)]
        [string] $Path
    )

    $Value | ConvertTo-Json -Depth 20 | Set-Content -Encoding UTF8 $Path
}

Push-Location $repoRoot
try {
    Write-Host "Applying search_outbox schema"
    Invoke-Psql -SqlPath $schemaPath | Out-Null

    Write-Host "Running search outbox transaction smoke"
    $resultJson = Invoke-Psql -SqlPath $smokeSqlPath -TuplesOnly
    $result = $resultJson | ConvertFrom-Json

    New-Item -ItemType Directory -Force -Path $resultDir | Out-Null

    $fullResultPath = Join-Path $resultDir "search-outbox-transaction-result.json"
    $commitPath = Join-Path $resultDir "commit-scenario-result.json"
    $updatePath = Join-Path $resultDir "update-scenario-result.json"
    $rollbackPath = Join-Path $resultDir "rollback-scenario-result.json"
    $statusChangePath = Join-Path $resultDir "status-change-scenario-result.json"
    $pendingPath = Join-Path $resultDir "pending-event-count-result.json"
    $summaryPath = Join-Path $resultDir "search-outbox-transaction-summary.md"

    Write-JsonFile -Value $result -Path $fullResultPath
    Write-JsonFile -Value $result.commitScenario -Path $commitPath
    Write-JsonFile -Value $result.updateScenario -Path $updatePath
    Write-JsonFile -Value $result.rollbackScenario -Path $rollbackPath
    Write-JsonFile -Value $result.statusChangeScenario -Path $statusChangePath
    Write-JsonFile -Value $result.counts -Path $pendingPath

    $summary = @"
# Search Outbox Transaction Smoke Summary

- DB target: $($result.dbTarget)
- Schema status: $($result.schemaStatus)
- Transaction atomicity: $($result.transactionAtomicity)
- Final smoke status: $($result.finalSmokeStatus)

| metric | value |
|---|---:|
| committed create product count | $($result.commitScenario.productCount) |
| create event count | $($result.counts.createEventCount) |
| update event count | $($result.counts.updateEventCount) |
| status-change event count | $($result.counts.statusChangeEventCount) |
| rollback product count | $($result.rollbackScenario.productCount) |
| rollback outbox count | $($result.counts.rollbackOutboxCount) |
| captured event count | $($result.counts.capturedEventCount) |
| pending event count | $($result.counts.pendingEventCount) |

Selected policy: soft delete/status change is the default search visibility mechanism; hard delete requires a tombstone event inserted before deleting the source row in the same transaction.

This smoke result is not a benchmark or production readiness claim.
"@

    $summary | Set-Content -Encoding UTF8 $summaryPath

    Write-Host "PASS: search outbox transaction smoke validation completed"
    Write-Host "Result artifacts: $resultDir"
} finally {
    Pop-Location
}
