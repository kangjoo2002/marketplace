param(
    [string] $RunId = "spring-replica-relay-smoke-local-$(Get-Date -Format 'yyyyMMdd-HHmm')",
    [int] $EventCount = 100,
    [int] $BatchSize = 100,
    [string] $PostgresContainer = "readpath-baseline-postgres",
    [string] $PostgresUser = "marketplace",
    [string] $PostgresDatabase = "marketplace",
    [string] $OpenSearchUrl = "http://localhost:9200"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$experimentDir = Resolve-Path (Join-Path $scriptDir "..")
$repoRoot = Resolve-Path (Join-Path $experimentDir "..\..\..")
$composeFile = Join-Path $experimentDir "docker-compose.spring-replica-smoke.yml"
$mappingPath = Join-Path $repoRoot "db\experiments\a1-opensearch-index-mapping-alias\mappings\products_v1_nested.json"
$measureSqlPath = Join-Path $experimentDir "sql\measure-indexing-lag.sql"
$resultDir = Join-Path $experimentDir "results\$RunId"
$writeAlias = "products_search_spring_replica_smoke_write"
$productStartId = -35000000

New-Item -ItemType Directory -Force -Path $resultDir | Out-Null

function Invoke-PsqlText {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Sql,
        [switch] $TuplesOnly
    )

    $arguments = @(
        "exec",
        "-i",
        $PostgresContainer,
        "psql",
        "-U",
        $PostgresUser,
        "-d",
        $PostgresDatabase,
        "-v",
        "ON_ERROR_STOP=1",
        "-q"
    )

    if ($TuplesOnly) {
        $arguments += @("-t", "-A")
    }

    $output = $Sql | docker @arguments
    if ($LASTEXITCODE -ne 0) {
        throw "psql failed with exit code $LASTEXITCODE"
    }
    return ($output -join "`n").Trim()
}

function Invoke-OpenSearch {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Method,
        [Parameter(Mandatory = $true)]
        [string] $Path,
        [object] $Body = $null,
        [string] $BodyPath = $null
    )

    $parameters = @{
        Method = $Method
        Uri = "$($OpenSearchUrl.TrimEnd('/'))/$($Path.TrimStart('/'))"
    }

    if ($BodyPath) {
        $parameters["Body"] = Get-Content -Raw $BodyPath
        $parameters["ContentType"] = "application/json"
    }
    elseif ($null -ne $Body) {
        if ($Body -is [string]) {
            $parameters["Body"] = $Body
        }
        else {
            $parameters["Body"] = $Body | ConvertTo-Json -Depth 80 -Compress
        }
        $parameters["ContentType"] = "application/json"
    }

    Invoke-RestMethod @parameters
}

function Convert-ElapsedMs {
    param([System.Diagnostics.Stopwatch] $Stopwatch)
    return [int64] $Stopwatch.Elapsed.TotalMilliseconds
}

function Get-Percentiles {
    param([long[]] $Values)

    if ($Values.Count -eq 0) {
        return [ordered]@{ p50 = 0; p95 = 0; p99 = 0; max = 0 }
    }

    $sorted = @($Values | Sort-Object)
    function Pick([double] $Percentile) {
        $index = [Math]::Ceiling($Percentile * $sorted.Count) - 1
        $index = [Math]::Max(0, [Math]::Min($index, $sorted.Count - 1))
        return [int64] $sorted[$index]
    }

    return [ordered]@{
        p50 = Pick 0.50
        p95 = Pick 0.95
        p99 = Pick 0.99
        max = [int64] $sorted[$sorted.Count - 1]
    }
}

function Initialize-OpenSearchTarget {
    param([Parameter(Mandatory = $true)][string] $IndexName)

    try {
        Invoke-OpenSearch -Method "DELETE" -Path $IndexName | Out-Null
    }
    catch {
        $statusCode = $null
        if ($null -ne $_.Exception.Response) {
            $statusCode = $_.Exception.Response.StatusCode.value__
        }
        if ($statusCode -ne 404) {
            throw
        }
    }

    Invoke-OpenSearch -Method "PUT" -Path $IndexName -BodyPath $mappingPath | Out-Null
    try {
        Invoke-OpenSearch -Method "POST" -Path "_aliases" -Body @{
            actions = @(@{ remove = @{ index = "*"; alias = $writeAlias } })
        } | Out-Null
    }
    catch {
        $statusCode = $null
        if ($null -ne $_.Exception.Response) {
            $statusCode = $_.Exception.Response.StatusCode.value__
        }
        if ($statusCode -ne 404) {
            throw
        }
    }
    Invoke-OpenSearch -Method "POST" -Path "_aliases" -Body @{
        actions = @(@{ add = @{ index = $IndexName; alias = $writeAlias } })
    } | Out-Null
}

function Initialize-PostgresSchema {
    $sql = @"
CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE TABLE IF NOT EXISTS products (
    id BIGSERIAL PRIMARY KEY,
    seller_id BIGINT NOT NULL,
    category_id BIGINT NOT NULL,
    brand_id BIGINT NOT NULL,
    status VARCHAR(20) NOT NULL,
    price INTEGER NOT NULL CHECK (price >= 0),
    rating NUMERIC(3,2) NOT NULL CHECK (rating >= 0 AND rating <= 5),
    review_count INTEGER NOT NULL CHECK (review_count >= 0),
    created_at TIMESTAMP NOT NULL,
    updated_at TIMESTAMP NOT NULL,
    CHECK (status IN ('ACTIVE', 'SOLD_OUT', 'DELETED'))
);

CREATE TABLE IF NOT EXISTS product_options (
    id BIGSERIAL PRIMARY KEY,
    product_id BIGINT NOT NULL REFERENCES products(id),
    color VARCHAR(20) NOT NULL,
    size VARCHAR(10) NOT NULL,
    stock_status VARCHAR(20) NOT NULL,
    CHECK (color IN ('BLACK', 'WHITE', 'RED', 'BLUE', 'GREEN', 'GRAY', 'NAVY', 'BEIGE')),
    CHECK (size IN ('XS', 'S', 'M', 'L', 'XL', 'FREE')),
    CHECK (stock_status IN ('IN_STOCK', 'LOW_STOCK', 'OUT_OF_STOCK'))
);

CREATE TABLE IF NOT EXISTS search_outbox (
    id BIGSERIAL PRIMARY KEY,
    aggregate_type VARCHAR(40) NOT NULL,
    aggregate_id BIGINT NOT NULL,
    event_type VARCHAR(80) NOT NULL,
    schema_version INTEGER NOT NULL DEFAULT 1,
    payload JSONB NOT NULL,
    status VARCHAR(20) NOT NULL DEFAULT 'PENDING',
    claim_token UUID,
    retry_count INTEGER NOT NULL DEFAULT 0,
    last_error TEXT,
    next_retry_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    processed_at TIMESTAMPTZ,
    CHECK (aggregate_type IN ('PRODUCT')),
    CHECK (event_type IN (
        'PRODUCT_CREATED',
        'PRODUCT_UPDATED',
        'PRODUCT_DELETED',
        'PRODUCT_STATUS_CHANGED',
        'PRODUCT_OPTION_CHANGED'
    )),
    CHECK (status IN ('PENDING', 'PROCESSING', 'DONE', 'FAILED')),
    CHECK (schema_version >= 1),
    CHECK (retry_count >= 0),
    CHECK (
        (status IN ('DONE', 'FAILED') AND processed_at IS NOT NULL)
        OR status IN ('PENDING', 'PROCESSING')
    )
);

CREATE INDEX IF NOT EXISTS idx_product_options_product_id
ON product_options(product_id);

CREATE INDEX IF NOT EXISTS idx_product_options_color_size_stock_product
ON product_options(color, size, stock_status, product_id);

CREATE INDEX IF NOT EXISTS idx_search_outbox_pending_next_retry
ON search_outbox(created_at, id)
WHERE status = 'PENDING';

CREATE INDEX IF NOT EXISTS idx_search_outbox_aggregate
ON search_outbox(aggregate_type, aggregate_id, id);

CREATE INDEX IF NOT EXISTS idx_search_outbox_status_created
ON search_outbox(status, created_at, id);
"@
    Invoke-PsqlText -Sql $sql | Out-Null
}

function Initialize-PostgresRows {
    param([Parameter(Mandatory = $true)][string] $CaseRunId)

    $products = 1..$EventCount | ForEach-Object {
        $productId = $productStartId - $_
        "($productId, $(3500 + $_), 75, $(900 + ($_ % 10)), 'ACTIVE', $(10000 + $_), 4.50, $_, now(), now())"
    }
    $options = 1..$EventCount | ForEach-Object {
        $productId = $productStartId - $_
        "($productId, 'BLACK', 'M', 'IN_STOCK')"
    }
    $outbox = 1..$EventCount | ForEach-Object {
        $productId = $productStartId - $_
        "('PRODUCT', $productId, 'PRODUCT_UPDATED', jsonb_build_object('productId', $productId, 'eventType', 'PRODUCT_UPDATED', 'smokeRun', '$CaseRunId', 'tombstone', false), now(), now())"
    }

    $sql = @"
DELETE FROM search_outbox WHERE payload->>'smokeRun' LIKE 'spring-replica-relay-smoke-%';
DELETE FROM product_options WHERE product_id BETWEEN -35000100 AND -35000001;
DELETE FROM products WHERE id BETWEEN -35000100 AND -35000001;
INSERT INTO products (id, seller_id, category_id, brand_id, status, price, rating, review_count, created_at, updated_at)
VALUES
$($products -join ",`n");
INSERT INTO product_options (product_id, color, size, stock_status)
VALUES
$($options -join ",`n");
INSERT INTO search_outbox (aggregate_type, aggregate_id, event_type, payload, created_at, updated_at)
VALUES
$($outbox -join ",`n");
"@
    Invoke-PsqlText -Sql $sql | Out-Null
}

function Get-StatusCounts {
    param([Parameter(Mandatory = $true)][string] $CaseRunId)

    $sql = @"
SELECT jsonb_build_object(
    'doneCount', COUNT(*) FILTER (WHERE status = 'DONE'),
    'failedCount', COUNT(*) FILTER (WHERE status = 'FAILED'),
    'pendingCount', COUNT(*) FILTER (WHERE status = 'PENDING'),
    'processingCount', COUNT(*) FILTER (WHERE status = 'PROCESSING'),
    'retryCount', COALESCE(SUM(retry_count), 0)
)::text
FROM search_outbox
WHERE payload->>'smokeRun' = '$CaseRunId';
"@
    return (Invoke-PsqlText -Sql $sql -TuplesOnly) | ConvertFrom-Json
}

function Wait-CaseDone {
    param(
        [Parameter(Mandatory = $true)]
        [string] $CaseRunId,
        [int] $TimeoutSeconds = 180
    )

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    do {
        $counts = Get-StatusCounts -CaseRunId $CaseRunId
        if ([int] $counts.doneCount -eq $EventCount -or [int] $counts.failedCount -gt 0) {
            return $counts
        }
        Start-Sleep -Milliseconds 500
    } while ($stopwatch.Elapsed.TotalSeconds -lt $TimeoutSeconds)

    return Get-StatusCounts -CaseRunId $CaseRunId
}

function Parse-RelayLogSamples {
    param([string[]] $LogLines)

    $pattern = "product_search_outbox_indexing_latency eventId=(\d+) aggregateId=(-?\d+) eventType=([A-Z_]+) resultStatus=([A-Z_]+) queueWaitMs=(\d+) sourceDocumentLoadMs=(\d+) openSearchWriteMs=(\d+) outboxStateTransitionMs=(\d+) relayProcessingMs=(\d+)"
    $samples = New-Object System.Collections.ArrayList
    foreach ($line in $LogLines) {
        $match = [regex]::Match($line, $pattern)
        if (-not $match.Success) {
            continue
        }
        [void] $samples.Add([pscustomobject]@{
            line = $line
            eventId = [long] $match.Groups[1].Value
            aggregateId = [long] $match.Groups[2].Value
            eventType = $match.Groups[3].Value
            resultStatus = $match.Groups[4].Value
            queueWaitMs = [long] $match.Groups[5].Value
            sourceDocumentLoadMs = [long] $match.Groups[6].Value
            openSearchWriteMs = [long] $match.Groups[7].Value
            outboxStateTransitionMs = [long] $match.Groups[8].Value
            relayProcessingMs = [long] $match.Groups[9].Value
        })
    }
    return @($samples.ToArray())
}

function Stop-ComposeProject {
    param([Parameter(Mandatory = $true)][string] $ProjectName)

    docker compose -p $ProjectName -f $composeFile down --remove-orphans | Out-Null
}

function Run-Case {
    param([Parameter(Mandatory = $true)][int] $ReplicaCount)

    $caseRunId = "$RunId-replica-$ReplicaCount"
    $projectName = "spring-replica-relay-smoke-$ReplicaCount"
    $indexName = "products_search_spring_replica_smoke_$($caseRunId -replace '[^0-9]', '')"

    Stop-ComposeProject -ProjectName $projectName
    Initialize-OpenSearchTarget -IndexName $indexName
    Initialize-PostgresSchema
    Initialize-PostgresRows -CaseRunId $caseRunId

    $runStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    docker compose -p $projectName -f $composeFile up -d --scale spring-app=$ReplicaCount | Out-Null

    try {
        $counts = Wait-CaseDone -CaseRunId $caseRunId
        $runStopwatch.Stop()
        $logLines = @(docker compose -p $projectName -f $composeFile logs --no-color spring-app)
    }
    finally {
        Stop-ComposeProject -ProjectName $projectName
    }

    $samples = Parse-RelayLogSamples -LogLines $logLines
    $measureSql = Get-Content -Raw $measureSqlPath
    $lagJsonText = $measureSql | docker exec -i $PostgresContainer psql -U $PostgresUser -d $PostgresDatabase -v ON_ERROR_STOP=1 -q -t -A -v smoke_run=$caseRunId
    if ($LASTEXITCODE -ne 0) {
        throw "measure-indexing-lag.sql failed"
    }
    $lagJson = (($lagJsonText -join "`n").Trim()) | ConvertFrom-Json

    $duplicateClaimEventIds = @(
        $samples |
            Group-Object eventId |
            Where-Object { $_.Count -gt 1 } |
            ForEach-Object { [long] $_.Name }
    )
    $failedRelayLineCount = @($samples | Where-Object { $_.resultStatus -ne "DONE" }).Count
    $staleClaimLineCount = @($logLines | Where-Object { $_ -like "*stale claim token*" }).Count

    $summary = [ordered]@{
        runId = $caseRunId
        environment = "local synthetic / local PostgreSQL + OpenSearch smoke"
        eventCount = $EventCount
        batchSize = $BatchSize
        replicaCount = $ReplicaCount
        doneEvents = [int] $counts.doneCount
        failedEvents = [int] $counts.failedCount
        pendingCount = [int] $counts.pendingCount
        processingCount = [int] $counts.processingCount
        retryCount = [int] $counts.retryCount
        totalProcessingTimeMs = Convert-ElapsedMs $runStopwatch
        totalIndexingLagMs = $lagJson.totalIndexingLagMs
        breakdown = [ordered]@{
            queueWaitMs = Get-Percentiles ([long[]] @($samples | ForEach-Object { $_.queueWaitMs }))
            sourceDocumentLoadMs = Get-Percentiles ([long[]] @($samples | ForEach-Object { $_.sourceDocumentLoadMs }))
            openSearchWriteMs = Get-Percentiles ([long[]] @($samples | ForEach-Object { $_.openSearchWriteMs }))
            outboxStateTransitionMs = Get-Percentiles ([long[]] @($samples | ForEach-Object { $_.outboxStateTransitionMs }))
            relayProcessingMs = Get-Percentiles ([long[]] @($samples | ForEach-Object { $_.relayProcessingMs }))
        }
        relayTimingLogLineCount = $samples.Count
        duplicateClaimDetected = $duplicateClaimEventIds.Count -gt 0
        duplicateClaimEventIds = $duplicateClaimEventIds
        failedRelayLineCount = $failedRelayLineCount
        staleClaimLineCount = $staleClaimLineCount
        retryOrFailedDetected = ([int] $counts.retryCount -gt 0 -or [int] $counts.failedCount -gt 0 -or $failedRelayLineCount -gt 0)
        indexName = $indexName
        writeAlias = $writeAlias
    }

    $summary | ConvertTo-Json -Depth 20 | Set-Content -Encoding UTF8 (Join-Path $resultDir "replica-$ReplicaCount-summary.json")

    if ($summary.doneEvents -ne $EventCount) {
        throw "Expected DONE events $EventCount, got $($summary.doneEvents)"
    }
    if ($summary.failedEvents -ne 0 -or $summary.pendingCount -ne 0 -or $summary.processingCount -ne 0) {
        throw "Expected FAILED/PENDING/PROCESSING 0, got failed=$($summary.failedEvents) pending=$($summary.pendingCount) processing=$($summary.processingCount)"
    }
    if ($summary.relayTimingLogLineCount -ne $EventCount) {
        throw "Expected timing line count $EventCount, got $($summary.relayTimingLogLineCount)"
    }
    if ($summary.duplicateClaimDetected) {
        throw "Duplicate claim detected: $($duplicateClaimEventIds -join ', ')"
    }
    if ($summary.retryOrFailedDetected) {
        throw "Retry or failed relay detected"
    }

    Write-Host "REPLICA_COUNT=$ReplicaCount"
    Write-Host "RUN_ID=$caseRunId"
    Write-Host "TOTAL_PROCESSING_TIME_MS=$($summary.totalProcessingTimeMs)"
    Write-Host "TOTAL_P95_MS=$($summary.totalIndexingLagMs.p95) QUEUE_P95_MS=$($summary.breakdown.queueWaitMs.p95) RELAY_P95_MS=$($summary.breakdown.relayProcessingMs.p95)"

    return [pscustomobject]@{
        summary = $summary
        timingLines = @($samples | Sort-Object eventId | Select-Object -First 20 | ForEach-Object { $_.line })
    }
}

& (Join-Path $repoRoot "gradlew.bat") bootJar
if ($LASTEXITCODE -ne 0) {
    throw "gradlew bootJar failed"
}

$caseResults = @(1, 2, 4 | ForEach-Object { Run-Case -ReplicaCount $_ })

$comparisonCases = @($caseResults | ForEach-Object {
    $summary = $_.summary
    [ordered]@{
        replicaCount = $summary.replicaCount
        batchSize = $summary.batchSize
        runId = $summary.runId
        eventCount = $summary.eventCount
        doneEvents = $summary.doneEvents
        failedEvents = $summary.failedEvents
        pendingCount = $summary.pendingCount
        processingCount = $summary.processingCount
        retryCount = $summary.retryCount
        totalProcessingTimeMs = $summary.totalProcessingTimeMs
        totalIndexingLagMs = $summary.totalIndexingLagMs
        queueWaitMs = $summary.breakdown.queueWaitMs
        sourceDocumentLoadMs = $summary.breakdown.sourceDocumentLoadMs
        openSearchWriteMs = $summary.breakdown.openSearchWriteMs
        outboxStateTransitionMs = $summary.breakdown.outboxStateTransitionMs
        relayProcessingMs = $summary.breakdown.relayProcessingMs
        relayTimingLogLineCount = $summary.relayTimingLogLineCount
        duplicateClaimDetected = $summary.duplicateClaimDetected
        retryOrFailedDetected = $summary.retryOrFailedDetected
    }
})

$comparison = [ordered]@{
    runId = $RunId
    analysisScope = "primary local synthetic Spring replica relay smoke"
    environment = "local synthetic / local PostgreSQL + OpenSearch smoke"
    eventCount = $EventCount
    batchSize = $BatchSize
    cases = $comparisonCases
    resultFiles = [ordered]@{
        comparisonSummary = "comparison-summary.json"
        replica1Summary = "replica-1-summary.json"
        replica2Summary = "replica-2-summary.json"
        replica4Summary = "replica-4-summary.json"
        relayLogSample = "relay-log-sample.txt"
    }
}

$comparison | ConvertTo-Json -Depth 30 | Set-Content -Encoding UTF8 (Join-Path $resultDir "comparison-summary.json")

$relayLogSample = @()
foreach ($caseResult in $caseResults) {
    $replicaCount = $caseResult.summary.replicaCount
    $relayLogSample += "# replicaCount=$replicaCount"
    $relayLogSample += $caseResult.timingLines
    $relayLogSample += ""
}
$relayLogSample | Set-Content -Encoding UTF8 (Join-Path $resultDir "relay-log-sample.txt")

Write-Host "RUN_ID=$RunId"
Write-Host "RESULT_DIR=$resultDir"
