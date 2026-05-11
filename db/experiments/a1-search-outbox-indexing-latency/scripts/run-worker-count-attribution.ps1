param(
    [string] $RunId = "worker-count-attribution-local-$(Get-Date -Format 'yyyyMMdd-HHmm')",
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
$mappingPath = Join-Path $repoRoot "db\experiments\a1-opensearch-index-mapping-alias\mappings\products_v1_nested.json"
$measureSqlPath = Join-Path $experimentDir "sql\measure-indexing-lag.sql"
$resultDir = Join-Path $experimentDir "results\$RunId"
$writeAlias = "products_search_worker_count_attribution_write"
$productStartId = -34000000

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
        "($productId, $(3400 + $_), 75, $(900 + ($_ % 10)), 'ACTIVE', $(10000 + $_), 4.50, $_, now(), now())"
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
DELETE FROM search_outbox WHERE payload->>'smokeRun' LIKE 'worker-count-attribution-%';
DELETE FROM product_options WHERE product_id BETWEEN -34000100 AND -34000001;
DELETE FROM products WHERE id BETWEEN -34000100 AND -34000001;
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

function Claim-Events {
    param([Parameter(Mandatory = $true)][string] $CaseRunId)

    $sql = @"
WITH claimed AS (
    SELECT id
    FROM search_outbox
    WHERE aggregate_type = 'PRODUCT'
      AND status = 'PENDING'
      AND payload->>'smokeRun' = '$CaseRunId'
    ORDER BY id
    FOR UPDATE SKIP LOCKED
    LIMIT $BatchSize
),
updated AS (
    UPDATE search_outbox outbox
    SET status = 'PROCESSING',
        claim_token = gen_random_uuid(),
        next_retry_at = NULL,
        updated_at = now()
    FROM claimed
    WHERE outbox.id = claimed.id
    RETURNING jsonb_build_object(
        'id', outbox.id,
        'aggregateId', outbox.aggregate_id,
        'eventType', outbox.event_type,
        'claimToken', outbox.claim_token,
        'createdAt', outbox.created_at,
        'claimedAt', outbox.updated_at
    )::text AS event_json
)
SELECT event_json FROM updated ORDER BY (event_json::jsonb->>'id')::bigint;
"@
    $text = Invoke-PsqlText -Sql $sql -TuplesOnly
    if ([string]::IsNullOrWhiteSpace($text)) {
        return @()
    }
    return @($text -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_ | ConvertFrom-Json })
}

function Split-Events {
    param(
        [Parameter(Mandatory = $true)]
        [object[]] $Events,
        [Parameter(Mandatory = $true)]
        [int] $WorkerCount
    )

    $chunks = New-Object System.Collections.ArrayList
    for ($workerIndex = 0; $workerIndex -lt $WorkerCount; $workerIndex++) {
        [void] $chunks.Add((New-Object System.Collections.ArrayList))
    }

    for ($eventIndex = 0; $eventIndex -lt $Events.Count; $eventIndex++) {
        $workerIndex = $eventIndex % $WorkerCount
        [void] $chunks[$workerIndex].Add($Events[$eventIndex])
    }

    return ,$chunks
}

function Convert-DateValueToOffset {
    param([object] $Value)

    if ($Value -is [datetime]) {
        return [datetimeoffset] $Value.ToUniversalTime()
    }
    if ($Value -is [datetimeoffset]) {
        return $Value.ToUniversalTime()
    }
    return [datetimeoffset]::Parse([string] $Value, [System.Globalization.CultureInfo]::InvariantCulture).ToUniversalTime()
}

$workerScript = {
    param(
        [string] $EventsJson,
        [int] $WorkerIndex,
        [string] $PostgresContainer,
        [string] $PostgresUser,
        [string] $PostgresDatabase,
        [string] $OpenSearchUrl,
        [string] $WriteAlias
    )

    $rawEvents = @($EventsJson | ConvertFrom-Json)
    $flattenedEvents = New-Object System.Collections.ArrayList
    foreach ($rawEvent in $rawEvents) {
        if ($rawEvent -is [System.Array]) {
            foreach ($innerEvent in $rawEvent) {
                [void] $flattenedEvents.Add($innerEvent)
            }
        }
        else {
            [void] $flattenedEvents.Add($rawEvent)
        }
    }
    $Events = @($flattenedEvents.ToArray())

    function Get-ScalarValue {
        param([object] $Value)
        return @($Value)[0]
    }

    function Invoke-PsqlTextInWorker {
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

    function Invoke-OpenSearchInWorker {
        param(
            [Parameter(Mandatory = $true)]
            [string] $Method,
            [Parameter(Mandatory = $true)]
            [string] $Path,
            [Parameter(Mandatory = $true)]
            [string] $Body
        )

        Invoke-RestMethod `
            -Method $Method `
            -Uri "$($OpenSearchUrl.TrimEnd('/'))/$($Path.TrimStart('/'))" `
            -Body $Body `
            -ContentType "application/json"
    }

    function Convert-ElapsedMsInWorker {
        param([System.Diagnostics.Stopwatch] $Stopwatch)
        return [int64] $Stopwatch.Elapsed.TotalMilliseconds
    }

    function Get-ProductDocumentJsonInWorker {
        param([long] $ProductId)

        $sql = @"
SELECT jsonb_build_object(
    'productId', p.id,
    'sellerId', p.seller_id,
    'categoryId', p.category_id,
    'brandId', p.brand_id,
    'status', p.status,
    'price', p.price,
    'rating', p.rating,
    'reviewCount', p.review_count,
    'createdAt', to_char(p.created_at, 'YYYY-MM-DD"T"HH24:MI:SS'),
    'updatedAt', to_char(p.updated_at, 'YYYY-MM-DD"T"HH24:MI:SS'),
    'sourceUpdatedAt', to_char(p.updated_at, 'YYYY-MM-DD"T"HH24:MI:SS'),
    'documentRefreshedAt', to_char(now() AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS'),
    'options', COALESCE(
        jsonb_agg(
            jsonb_build_object(
                'color', po.color,
                'size', po.size,
                'stockStatus', po.stock_status
            )
            ORDER BY po.id
        ) FILTER (WHERE po.id IS NOT NULL),
        '[]'::jsonb
    )
)::text
FROM products p
LEFT JOIN product_options po ON po.product_id = p.id
WHERE p.id = $ProductId
GROUP BY p.id, p.seller_id, p.category_id, p.brand_id, p.status, p.price, p.rating, p.review_count, p.created_at, p.updated_at;
"@
        return Invoke-PsqlTextInWorker -Sql $sql -TuplesOnly
    }

    function Mark-DoneInWorker {
        param(
            [long] $EventId,
            [string] $ClaimToken
        )

        $sql = @"
UPDATE search_outbox
SET status = 'DONE',
    last_error = NULL,
    claim_token = NULL,
    processed_at = now(),
    updated_at = now()
WHERE id = $EventId
  AND status = 'PROCESSING'
  AND claim_token = '$ClaimToken'::uuid;
"@
        Invoke-PsqlTextInWorker -Sql $sql | Out-Null
    }

    $samples = @()
    foreach ($event in $Events) {
        $eventId = [long] (Get-ScalarValue $event.id)
        $aggregateId = [long] (Get-ScalarValue $event.aggregateId)
        $eventType = [string] (Get-ScalarValue $event.eventType)
        $claimToken = [string] (Get-ScalarValue $event.claimToken)
        $eventStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        $queueMs = [long] (Get-ScalarValue $event.queueWaitMs)

        $sourceStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        $documentJson = Get-ProductDocumentJsonInWorker -ProductId $aggregateId
        $sourceStopwatch.Stop()

        $writeStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        Invoke-OpenSearchInWorker -Method "PUT" -Path "$WriteAlias/_doc/$aggregateId" -Body $documentJson | Out-Null
        $writeStopwatch.Stop()

        $transitionStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        Mark-DoneInWorker -EventId $eventId -ClaimToken $claimToken
        $transitionStopwatch.Stop()
        $eventStopwatch.Stop()

        $samples += [pscustomobject]@{
            workerIndex = $WorkerIndex
            eventId = $eventId
            aggregateId = $aggregateId
            eventType = $eventType
            queueWaitMs = $queueMs
            sourceDocumentLoadMs = Convert-ElapsedMsInWorker $sourceStopwatch
            openSearchWriteMs = Convert-ElapsedMsInWorker $writeStopwatch
            outboxStateTransitionMs = Convert-ElapsedMsInWorker $transitionStopwatch
            relayProcessingMs = Convert-ElapsedMsInWorker $eventStopwatch
        }
    }

    return $samples
}

function Run-Case {
    param([Parameter(Mandatory = $true)][int] $WorkerCount)

    $caseRunId = "$RunId-worker-$WorkerCount"
    $indexName = "products_search_worker_count_attribution_$($caseRunId -replace '[^0-9]', '')"

    Initialize-OpenSearchTarget -IndexName $indexName
    Initialize-PostgresSchema
    Initialize-PostgresRows -CaseRunId $caseRunId

    $events = @(Claim-Events -CaseRunId $caseRunId)
    if ($events.Count -ne $EventCount) {
        throw "Expected claimed events $EventCount, got $($events.Count)"
    }

    $events = @($events | ForEach-Object {
        $createdAt = Convert-DateValueToOffset $_.createdAt
        $claimedAt = Convert-DateValueToOffset $_.claimedAt
        [pscustomobject]@{
            id = [long] $_.id
            aggregateId = [long] $_.aggregateId
            eventType = [string] $_.eventType
            claimToken = [string] $_.claimToken
            queueWaitMs = [Math]::Max(0, [int64] ($claimedAt - $createdAt).TotalMilliseconds)
        }
    })

    $chunks = Split-Events -Events $events -WorkerCount $WorkerCount
    $runStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $jobs = @()
    for ($workerIndex = 0; $workerIndex -lt $WorkerCount; $workerIndex++) {
        $workerEvents = @($chunks[$workerIndex].ToArray())
        $chunkJson = ConvertTo-Json -InputObject $workerEvents -Depth 20 -Compress
        $jobs += Start-Job -ScriptBlock $workerScript -ArgumentList @(
            $chunkJson,
            $workerIndex,
            $PostgresContainer,
            $PostgresUser,
            $PostgresDatabase,
            $OpenSearchUrl,
            $writeAlias
        )
    }

    Wait-Job -Job $jobs | Out-Null
    $samples = @()
    foreach ($job in $jobs) {
        if ($job.State -ne "Completed") {
            $jobError = Receive-Job -Job $job -ErrorAction SilentlyContinue -ErrorVariable receiveErrors
            Remove-Job -Job $jobs -Force
            throw "Worker job failed: $($receiveErrors | Out-String) $($jobError | Out-String)"
        }
        $samples += Receive-Job -Job $job
    }
    Remove-Job -Job $jobs
    $runStopwatch.Stop()

    $orderedSamples = @($samples | Sort-Object eventId)
    $timingLines = @($orderedSamples | ForEach-Object {
        "product_search_outbox_indexing_latency workerIndex=$($_.workerIndex) eventId=$($_.eventId) aggregateId=$($_.aggregateId) eventType=$($_.eventType) resultStatus=DONE queueWaitMs=$($_.queueWaitMs) sourceDocumentLoadMs=$($_.sourceDocumentLoadMs) openSearchWriteMs=$($_.openSearchWriteMs) outboxStateTransitionMs=$($_.outboxStateTransitionMs) relayProcessingMs=$($_.relayProcessingMs)"
    })

    $measureSql = Get-Content -Raw $measureSqlPath
    $lagJsonText = $measureSql | docker exec -i $PostgresContainer psql -U $PostgresUser -d $PostgresDatabase -v ON_ERROR_STOP=1 -q -t -A -v smoke_run=$caseRunId
    if ($LASTEXITCODE -ne 0) {
        throw "measure-indexing-lag.sql failed"
    }
    $lagJson = (($lagJsonText -join "`n").Trim()) | ConvertFrom-Json

    $summary = [ordered]@{
        runId = $caseRunId
        environment = "local synthetic / local PostgreSQL + OpenSearch smoke"
        eventCount = $EventCount
        batchSize = $BatchSize
        workerCount = $WorkerCount
        claimedEvents = $events.Count
        doneEvents = [int] $lagJson.statusCounts.doneCount
        failedEvents = [int] $lagJson.statusCounts.failedCount
        pendingCount = [int] $lagJson.statusCounts.pendingCount
        processingCount = [int] $lagJson.statusCounts.processingCount
        totalProcessingTimeMs = Convert-ElapsedMs $runStopwatch
        totalIndexingLagMs = $lagJson.totalIndexingLagMs
        breakdown = [ordered]@{
            queueWaitMs = Get-Percentiles ([long[]] @($orderedSamples | ForEach-Object { $_.queueWaitMs }))
            sourceDocumentLoadMs = Get-Percentiles ([long[]] @($orderedSamples | ForEach-Object { $_.sourceDocumentLoadMs }))
            openSearchWriteMs = Get-Percentiles ([long[]] @($orderedSamples | ForEach-Object { $_.openSearchWriteMs }))
            outboxStateTransitionMs = Get-Percentiles ([long[]] @($orderedSamples | ForEach-Object { $_.outboxStateTransitionMs }))
            relayProcessingMs = Get-Percentiles ([long[]] @($orderedSamples | ForEach-Object { $_.relayProcessingMs }))
        }
        openSearchWriteDeleteCallCount = $orderedSamples.Count
        relayTimingLogLineCount = $timingLines.Count
        indexName = $indexName
        writeAlias = $writeAlias
    }

    $summary | ConvertTo-Json -Depth 20 | Set-Content -Encoding UTF8 (Join-Path $resultDir "worker-$WorkerCount-summary.json")

    if ($summary.doneEvents -ne $EventCount) {
        throw "Expected DONE events $EventCount, got $($summary.doneEvents)"
    }
    if ($summary.failedEvents -ne 0) {
        throw "Expected FAILED events 0, got $($summary.failedEvents)"
    }
    if ($summary.openSearchWriteDeleteCallCount -ne $EventCount) {
        throw "Expected OpenSearch write/delete call count $EventCount, got $($summary.openSearchWriteDeleteCallCount)"
    }
    if ($summary.relayTimingLogLineCount -ne $EventCount) {
        throw "Expected timing line count $EventCount, got $($summary.relayTimingLogLineCount)"
    }

    Write-Host "WORKER_COUNT=$WorkerCount"
    Write-Host "RUN_ID=$caseRunId"
    Write-Host "TOTAL_PROCESSING_TIME_MS=$($summary.totalProcessingTimeMs)"
    Write-Host "TOTAL_P95_MS=$($summary.totalIndexingLagMs.p95) QUEUE_P95_MS=$($summary.breakdown.queueWaitMs.p95) RELAY_P95_MS=$($summary.breakdown.relayProcessingMs.p95)"

    return [pscustomobject]@{
        summary = $summary
        timingLines = $timingLines
    }
}

$caseResults = @(1, 2, 4 | ForEach-Object { Run-Case -WorkerCount $_ })

$comparisonCases = @($caseResults | ForEach-Object {
    $summary = $_.summary
    [ordered]@{
        workerCount = $summary.workerCount
        batchSize = $summary.batchSize
        runId = $summary.runId
        eventCount = $summary.eventCount
        claimedEvents = $summary.claimedEvents
        doneEvents = $summary.doneEvents
        failedEvents = $summary.failedEvents
        pendingCount = $summary.pendingCount
        processingCount = $summary.processingCount
        totalProcessingTimeMs = $summary.totalProcessingTimeMs
        totalIndexingLagMs = $summary.totalIndexingLagMs
        queueWaitMs = $summary.breakdown.queueWaitMs
        sourceDocumentLoadMs = $summary.breakdown.sourceDocumentLoadMs
        openSearchWriteMs = $summary.breakdown.openSearchWriteMs
        outboxStateTransitionMs = $summary.breakdown.outboxStateTransitionMs
        relayProcessingMs = $summary.breakdown.relayProcessingMs
        openSearchWriteDeleteCallCount = $summary.openSearchWriteDeleteCallCount
        relayTimingLogLineCount = $summary.relayTimingLogLineCount
    }
})

$comparison = [ordered]@{
    runId = $RunId
    analysisScope = "script-based WIP/reference only; not the primary Spring replica conclusion"
    environment = "local synthetic / local PostgreSQL + OpenSearch smoke"
    eventCount = $EventCount
    batchSize = $BatchSize
    cases = $comparisonCases
    resultFiles = [ordered]@{
        comparisonSummary = "comparison-summary.json"
        worker1Summary = "worker-1-summary.json"
        worker2Summary = "worker-2-summary.json"
        worker4Summary = "worker-4-summary.json"
        relayLogSample = "relay-log-sample.txt"
    }
}

$comparison | ConvertTo-Json -Depth 30 | Set-Content -Encoding UTF8 (Join-Path $resultDir "comparison-summary.json")

$relayLogSample = @()
foreach ($caseResult in $caseResults) {
    $workerCount = $caseResult.summary.workerCount
    $relayLogSample += "# workerCount=$workerCount"
    $relayLogSample += @($caseResult.timingLines | Select-Object -First 20)
    $relayLogSample += ""
}
$relayLogSample | Set-Content -Encoding UTF8 (Join-Path $resultDir "relay-log-sample.txt")

Write-Host "RUN_ID=$RunId"
Write-Host "RESULT_DIR=$resultDir"
