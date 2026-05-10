param(
    [string] $RunId = "queue-wait-attribution-local-$(Get-Date -Format 'yyyyMMdd-HHmm')",
    [int] $EventCount = 100,
    [string] $PostgresContainer = "readpath-baseline-postgres",
    [string] $PostgresUser = "marketplace",
    [string] $PostgresDatabase = "marketplace",
    [string] $OpenSearchUrl = "http://localhost:9200"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$experimentDir = Resolve-Path (Join-Path $scriptDir "..")
$resultsRoot = Join-Path $experimentDir "results"
$resultDir = Join-Path $resultsRoot $RunId
$singleRunner = Join-Path $scriptDir "run-single-index-baseline.ps1"

New-Item -ItemType Directory -Force -Path $resultDir | Out-Null

function Copy-CaseSummary {
    param(
        [Parameter(Mandatory = $true)]
        [string] $CaseRunId,
        [Parameter(Mandatory = $true)]
        [int] $BatchSize
    )

    $caseDir = Join-Path $resultsRoot $CaseRunId
    $summaryPath = Join-Path $caseDir "indexing-lag-summary.json"
    $summary = Get-Content -Raw $summaryPath | ConvertFrom-Json

    Copy-Item -Force $summaryPath (Join-Path $resultDir "batch-$BatchSize-summary.json")

    return [ordered]@{
        batchSize = $BatchSize
        workerCount = 1
        runId = $summary.runId
        eventCount = [int] $summary.eventCount
        claimedEvents = [int] $summary.claimedEvents
        doneEvents = [int] $summary.doneEvents
        failedEvents = [int] $summary.failedEvents
        pendingCount = [int] $summary.pendingCount
        processingCount = [int] $summary.processingCount
        totalProcessingTimeMs = [int64] $summary.totalProcessingTimeMs
        totalIndexingLagMs = $summary.totalIndexingLagMs
        queueWaitMs = $summary.breakdown.queueWaitMs
        sourceDocumentLoadMs = $summary.breakdown.sourceDocumentLoadMs
        openSearchWriteMs = $summary.breakdown.openSearchWriteMs
        outboxStateTransitionMs = $summary.breakdown.outboxStateTransitionMs
        relayProcessingMs = $summary.breakdown.relayProcessingMs
        openSearchWriteDeleteCallCount = [int] $summary.openSearchWriteDeleteCallCount
        relayTimingLogLineCount = [int] $summary.relayTimingLogLineCount
        relayLogSamplePath = "relay-log-sample.txt"
    }
}

function Remove-GeneratedCaseDir {
    param([Parameter(Mandatory = $true)][string] $CaseRunId)

    $caseDir = Resolve-Path (Join-Path $resultsRoot $CaseRunId)
    $resolvedResultsRoot = Resolve-Path $resultsRoot
    if (-not $caseDir.Path.StartsWith($resolvedResultsRoot.Path, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to remove case directory outside results root: $($caseDir.Path)"
    }
    Remove-Item -Recurse -Force -LiteralPath $caseDir.Path
}

$case20RunId = "$RunId-batch-20"
$case100RunId = "$RunId-batch-100"

& $singleRunner `
    -RunId $case20RunId `
    -EventCount $EventCount `
    -PostgresContainer $PostgresContainer `
    -PostgresUser $PostgresUser `
    -PostgresDatabase $PostgresDatabase `
    -OpenSearchUrl $OpenSearchUrl `
    -BatchSize 20

& $singleRunner `
    -RunId $case100RunId `
    -EventCount $EventCount `
    -PostgresContainer $PostgresContainer `
    -PostgresUser $PostgresUser `
    -PostgresDatabase $PostgresDatabase `
    -OpenSearchUrl $OpenSearchUrl `
    -BatchSize 100

$case20 = Copy-CaseSummary -CaseRunId $case20RunId -BatchSize 20
$case100 = Copy-CaseSummary -CaseRunId $case100RunId -BatchSize 100

$comparison = [ordered]@{
    runId = $RunId
    environment = "local synthetic / local PostgreSQL + OpenSearch smoke"
    eventCount = $EventCount
    workerCount = 1
    cases = @($case20, $case100)
    resultFiles = [ordered]@{
        comparisonSummary = "comparison-summary.json"
        batch20Summary = "batch-20-summary.json"
        batch100Summary = "batch-100-summary.json"
        relayLogSample = "relay-log-sample.txt"
    }
}

$comparison | ConvertTo-Json -Depth 30 | Set-Content -Encoding UTF8 (Join-Path $resultDir "comparison-summary.json")

$relayLogSample = @()
$relayLogSample += "# batchSize=20"
$relayLogSample += Get-Content (Join-Path $resultsRoot "$case20RunId\relay-log-sample.txt")
$relayLogSample += ""
$relayLogSample += "# batchSize=100"
$relayLogSample += Get-Content (Join-Path $resultsRoot "$case100RunId\relay-log-sample.txt")
$relayLogSample | Set-Content -Encoding UTF8 (Join-Path $resultDir "relay-log-sample.txt")

Remove-GeneratedCaseDir -CaseRunId $case20RunId
Remove-GeneratedCaseDir -CaseRunId $case100RunId

Write-Host "RUN_ID=$RunId"
Write-Host "RESULT_DIR=$resultDir"
Write-Host "BATCH_20_TOTAL_P95_MS=$($case20.totalIndexingLagMs.p95) QUEUE_P95_MS=$($case20.queueWaitMs.p95)"
Write-Host "BATCH_100_TOTAL_P95_MS=$($case100.totalIndexingLagMs.p95) QUEUE_P95_MS=$($case100.queueWaitMs.p95)"
