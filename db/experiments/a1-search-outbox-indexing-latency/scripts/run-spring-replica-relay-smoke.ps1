param(
    [string] $RunId = "spring-replica-scaling-smoke-local-$(Get-Date -Format 'yyyyMMdd-HHmm')",
    [int] $EventCount = 1000,
    [int] $BatchSize = 100,
    [int[]] $ReplicaCounts = @(1, 2, 4),
    [int] $HealthTimeoutSeconds = 180,
    [int] $StabilizationSeconds = 3,
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
$productStartId = -36000000

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

    $sql = @"
INSERT INTO products (id, seller_id, category_id, brand_id, status, price, rating, review_count, created_at, updated_at)
SELECT
    $productStartId - seq,
    3500 + seq,
    75,
    900 + (seq % 10),
    'ACTIVE',
    10000 + seq,
    4.50,
    seq,
    now(),
    now()
FROM generate_series(1, $EventCount) AS seq;

INSERT INTO product_options (product_id, color, size, stock_status)
SELECT
    $productStartId - seq,
    'BLACK',
    'M',
    'IN_STOCK'
FROM generate_series(1, $EventCount) AS seq;

INSERT INTO search_outbox (aggregate_type, aggregate_id, event_type, payload, created_at, updated_at)
SELECT
    'PRODUCT',
    $productStartId - seq,
    'PRODUCT_UPDATED',
    jsonb_build_object(
        'productId', $productStartId - seq,
        'eventType', 'PRODUCT_UPDATED',
        'smokeRun', '$CaseRunId',
        'tombstone', false
    ),
    now(),
    now()
FROM generate_series(1, $EventCount) AS seq;
"@
    Invoke-PsqlText -Sql $sql | Out-Null
}

function Clear-PostgresSmokeRows {
    $sql = @"
DELETE FROM search_outbox WHERE payload->>'smokeRun' LIKE 'spring-replica-%';
DELETE FROM product_options WHERE product_id BETWEEN -36010000 AND -36000001;
DELETE FROM products WHERE id BETWEEN -36010000 AND -36000001;
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

    $pattern = "^(?<replica>spring-app-\d+)\s+\|\s+(?<doneAt>\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d+Z).*product_search_outbox_indexing_latency eventId=(?<eventId>\d+) aggregateId=(?<aggregateId>-?\d+) eventType=(?<eventType>[A-Z_]+) resultStatus=(?<resultStatus>[A-Z_]+) queueWaitMs=(?<queueWaitMs>\d+) sourceDocumentLoadMs=(?<sourceDocumentLoadMs>\d+) openSearchWriteMs=(?<openSearchWriteMs>\d+) outboxStateTransitionMs=(?<outboxStateTransitionMs>\d+) relayProcessingMs=(?<relayProcessingMs>\d+)"
    $samples = New-Object System.Collections.ArrayList
    foreach ($line in $LogLines) {
        $match = [regex]::Match($line, $pattern)
        if (-not $match.Success) {
            continue
        }
        [void] $samples.Add([pscustomobject]@{
            line = $line
            replica = $match.Groups["replica"].Value
            doneAt = [datetimeoffset]::Parse($match.Groups["doneAt"].Value, [System.Globalization.CultureInfo]::InvariantCulture)
            eventId = [long] $match.Groups["eventId"].Value
            aggregateId = [long] $match.Groups["aggregateId"].Value
            eventType = $match.Groups["eventType"].Value
            resultStatus = $match.Groups["resultStatus"].Value
            queueWaitMs = [long] $match.Groups["queueWaitMs"].Value
            sourceDocumentLoadMs = [long] $match.Groups["sourceDocumentLoadMs"].Value
            openSearchWriteMs = [long] $match.Groups["openSearchWriteMs"].Value
            outboxStateTransitionMs = [long] $match.Groups["outboxStateTransitionMs"].Value
            relayProcessingMs = [long] $match.Groups["relayProcessingMs"].Value
        })
    }
    return @($samples.ToArray())
}

function Get-ReplicaClaimStats {
    param(
        [object[]] $Samples,
        [Parameter(Mandatory = $true)][int] $ReplicaCount
    )

    $validSamples = @(
        $Samples |
            Where-Object { $null -ne $_ -and $null -ne $_.PSObject.Properties["replica"] }
    )

    return @(
        1..$ReplicaCount |
            ForEach-Object {
                $replicaName = "spring-app-$_"
                $replicaSamples = @($validSamples | Where-Object { $_.replica -eq $replicaName })
                if ($replicaSamples.Count -eq 0) {
                    [ordered]@{
                        replica = $replicaName
                        claimCount = 0
                        timingLogLineCount = 0
                        batchClaimCount = 0
                        firstClaimAt = $null
                        lastDoneAt = $null
                    }
                }
                else {
                    $firstClaimAt = @(
                        $replicaSamples |
                            ForEach-Object { $_.doneAt.AddMilliseconds(-1 * $_.relayProcessingMs) } |
                            Sort-Object |
                            Select-Object -First 1
                    )[0]
                    $lastDoneAt = @(
                        $replicaSamples |
                            ForEach-Object { $_.doneAt } |
                            Sort-Object |
                            Select-Object -Last 1
                    )[0]
                    [ordered]@{
                        replica = $replicaName
                        claimCount = $replicaSamples.Count
                        timingLogLineCount = $replicaSamples.Count
                        batchClaimCount = @($replicaSamples | Group-Object queueWaitMs).Count
                        firstClaimAt = $firstClaimAt.ToString("o")
                        lastDoneAt = $lastDoneAt.ToString("o")
                    }
                }
            }
    )
}

function Stop-ComposeProject {
    param([Parameter(Mandatory = $true)][string] $ProjectName)

    docker compose -p $ProjectName -f $composeFile down --remove-orphans | Out-Null
}

function Get-SpringAppContainerIds {
    param([Parameter(Mandatory = $true)][string] $ProjectName)

    return @(
        docker compose -p $ProjectName -f $composeFile ps -q spring-app |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )
}

function Get-ContainerPublishedPort {
    param([Parameter(Mandatory = $true)][string] $ContainerId)

    $portText = docker port $ContainerId 8080/tcp
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($portText)) {
        return $null
    }

    $firstBinding = @($portText)[0]
    $match = [regex]::Match($firstBinding, ":(\d+)$")
    if (-not $match.Success) {
        return $null
    }

    return [int] $match.Groups[1].Value
}

function Test-SpringAppHealth {
    param([Parameter(Mandatory = $true)][int] $Port)

    try {
        $response = Invoke-RestMethod `
            -Method "GET" `
            -Uri "http://localhost:$Port/actuator/health" `
            -TimeoutSec 2
        return $response.status -eq "UP"
    }
    catch {
        return $false
    }
}

function Wait-SpringReplicasHealthy {
    param(
        [Parameter(Mandatory = $true)][string] $ProjectName,
        [Parameter(Mandatory = $true)][int] $ReplicaCount
    )

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    do {
        $containerIds = @(Get-SpringAppContainerIds -ProjectName $ProjectName)
        if ($containerIds.Count -eq $ReplicaCount) {
            $ports = @($containerIds | ForEach-Object { Get-ContainerPublishedPort -ContainerId $_ })
            if ($ports.Count -eq $ReplicaCount -and -not ($ports | Where-Object { $null -eq $_ })) {
                $healthyCount = @($ports | Where-Object { Test-SpringAppHealth -Port $_ }).Count
                if ($healthyCount -eq $ReplicaCount) {
                    return $ports
                }
            }
        }

        Start-Sleep -Milliseconds 1000
    } while ($stopwatch.Elapsed.TotalSeconds -lt $HealthTimeoutSeconds)

    throw "Spring app replicas did not become healthy within $HealthTimeoutSeconds seconds"
}

function Run-Case {
    param([Parameter(Mandatory = $true)][int] $ReplicaCount)

    $caseRunId = "$RunId-replica-$ReplicaCount"
    $projectName = "spring-replica-relay-smoke-$ReplicaCount"
    $indexName = "products_search_spring_replica_smoke_$($caseRunId -replace '[^0-9]', '')"

    Stop-ComposeProject -ProjectName $projectName
    Initialize-OpenSearchTarget -IndexName $indexName
    Initialize-PostgresSchema
    Clear-PostgresSmokeRows

    docker compose -p $projectName -f $composeFile up -d --scale spring-app=$ReplicaCount | Out-Null

    try {
        $healthPorts = @(Wait-SpringReplicasHealthy -ProjectName $projectName -ReplicaCount $ReplicaCount)
        Start-Sleep -Seconds $StabilizationSeconds

        $logSince = (Get-Date).ToUniversalTime().ToString("o")
        Initialize-PostgresRows -CaseRunId $caseRunId
        $runStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        $counts = Wait-CaseDone -CaseRunId $caseRunId
        $runStopwatch.Stop()
        $logLines = @(docker compose -p $projectName -f $composeFile logs --no-color --since $logSince spring-app)
    }
    finally {
        Stop-ComposeProject -ProjectName $projectName
    }

    $samples = @(Parse-RelayLogSamples -LogLines $logLines)
    $replicaClaimStats = @(Get-ReplicaClaimStats -Samples $samples -ReplicaCount $ReplicaCount)
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
        batchClaimCount = @($samples | Group-Object queueWaitMs).Count
        firstClaimAt = @($replicaClaimStats | ForEach-Object { $_.firstClaimAt } | Sort-Object | Select-Object -First 1)[0]
        lastDoneAt = @($replicaClaimStats | ForEach-Object { $_.lastDoneAt } | Sort-Object | Select-Object -Last 1)[0]
        replicaClaimStats = $replicaClaimStats
        duplicateClaimDetected = $duplicateClaimEventIds.Count -gt 0
        duplicateClaimEventIds = $duplicateClaimEventIds
        failedRelayLineCount = $failedRelayLineCount
        staleClaimLineCount = $staleClaimLineCount
        retryOrFailedDetected = ([int] $counts.retryCount -gt 0 -or [int] $counts.failedCount -gt 0 -or $failedRelayLineCount -gt 0)
        healthPorts = $healthPorts
        stabilizationSeconds = $StabilizationSeconds
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

$caseResults = @($ReplicaCounts | ForEach-Object { Run-Case -ReplicaCount $_ })

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
        batchClaimCount = $summary.batchClaimCount
        firstClaimAt = $summary.firstClaimAt
        lastDoneAt = $summary.lastDoneAt
        replicaClaimStats = $summary.replicaClaimStats
        duplicateClaimDetected = $summary.duplicateClaimDetected
        retryOrFailedDetected = $summary.retryOrFailedDetected
        healthPorts = $summary.healthPorts
        stabilizationSeconds = $summary.stabilizationSeconds
    }
})

$comparison = [ordered]@{
    runId = $RunId
    analysisScope = "primary local synthetic steady-state Spring replica scaling smoke"
    environment = "local synthetic / local PostgreSQL + OpenSearch smoke"
    eventCount = $EventCount
    batchSize = $BatchSize
    healthCheck = "all Spring app replicas returned actuator health UP before smoke rows were inserted"
    stabilizationSeconds = $StabilizationSeconds
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
