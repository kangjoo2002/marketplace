param(
    [string] $RunId = "single-index-baseline-local-$(Get-Date -Format 'yyyyMMdd-HHmm')",
    [int] $EventCount = 100,
    [string] $PostgresContainer = "readpath-baseline-postgres",
    [string] $PostgresUser = "marketplace",
    [string] $PostgresDatabase = "marketplace",
    [string] $OpenSearchUrl = "http://localhost:9200",
    [int] $BatchSize = 20
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$experimentDir = Resolve-Path (Join-Path $scriptDir "..")
$repoRoot = Resolve-Path (Join-Path $experimentDir "..\..\..")
$mappingPath = Join-Path $repoRoot "db\experiments\a1-opensearch-index-mapping-alias\mappings\products_v1_nested.json"
$measureSqlPath = Join-Path $experimentDir "sql\measure-indexing-lag.sql"
$resultDir = Join-Path $experimentDir "results\$RunId"
$indexName = "products_search_single_index_baseline_$($RunId -replace '[^0-9]', '')"
$writeAlias = "products_search_single_index_baseline_write"
$productStartId = -33000000

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
    try {
        Invoke-OpenSearch -Method "DELETE" -Path $indexName | Out-Null
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

    Invoke-OpenSearch -Method "PUT" -Path $indexName -BodyPath $mappingPath | Out-Null
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
        actions = @(@{ add = @{ index = $indexName; alias = $writeAlias } })
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
    $products = 1..$EventCount | ForEach-Object {
        $productId = $productStartId - $_
        "($productId, $(3300 + $_), 75, $(900 + ($_ % 10)), 'ACTIVE', $(10000 + $_), 4.50, $_, now(), now())"
    }
    $options = 1..$EventCount | ForEach-Object {
        $productId = $productStartId - $_
        "($productId, 'BLACK', 'M', 'IN_STOCK')"
    }
    $outbox = 1..$EventCount | ForEach-Object {
        $productId = $productStartId - $_
        "('PRODUCT', $productId, 'PRODUCT_UPDATED', jsonb_build_object('productId', $productId, 'eventType', 'PRODUCT_UPDATED', 'smokeRun', '$RunId', 'tombstone', false), now(), now())"
    }

    $sql = @"
DELETE FROM search_outbox WHERE payload->>'smokeRun' LIKE 'single-index-baseline-%';
DELETE FROM product_options WHERE product_id BETWEEN -33000100 AND -33000001;
DELETE FROM products WHERE id BETWEEN -33000100 AND -33000001;
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
    $sql = @"
WITH claimed AS (
    SELECT id
    FROM search_outbox
    WHERE aggregate_type = 'PRODUCT'
      AND status = 'PENDING'
      AND payload->>'smokeRun' = '$RunId'
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

function Get-ProductDocumentJson {
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
    return Invoke-PsqlText -Sql $sql -TuplesOnly
}

function Mark-Done {
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
    Invoke-PsqlText -Sql $sql | Out-Null
}

Initialize-OpenSearchTarget
Initialize-PostgresSchema
Initialize-PostgresRows

$queueWaitMs = New-Object System.Collections.Generic.List[long]
$sourceDocumentLoadMs = New-Object System.Collections.Generic.List[long]
$openSearchWriteMs = New-Object System.Collections.Generic.List[long]
$outboxStateTransitionMs = New-Object System.Collections.Generic.List[long]
$relayProcessingMs = New-Object System.Collections.Generic.List[long]
$timingLines = New-Object System.Collections.Generic.List[string]
$writeCallCount = 0
$claimedCount = 0

$runStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
while ($claimedCount -lt $EventCount) {
    $events = @(Claim-Events)
    if ($events.Count -eq 0) {
        break
    }

    foreach ($event in $events) {
        $eventStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        $createdAt = [datetimeoffset]::Parse([string] $event.createdAt)
        $claimedAt = [datetimeoffset]::Parse([string] $event.claimedAt)
        $queueMs = [Math]::Max(0, [int64] ($claimedAt - $createdAt).TotalMilliseconds)

        $sourceStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        $documentJson = Get-ProductDocumentJson -ProductId ([long] $event.aggregateId)
        $sourceStopwatch.Stop()

        $writeStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        Invoke-OpenSearch -Method "PUT" -Path "$writeAlias/_doc/$($event.aggregateId)" -Body $documentJson | Out-Null
        $writeStopwatch.Stop()
        $writeCallCount++

        $transitionStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        Mark-Done -EventId ([long] $event.id) -ClaimToken ([string] $event.claimToken)
        $transitionStopwatch.Stop()
        $eventStopwatch.Stop()

        $queueWaitMs.Add($queueMs)
        $sourceDocumentLoadMs.Add((Convert-ElapsedMs $sourceStopwatch))
        $openSearchWriteMs.Add((Convert-ElapsedMs $writeStopwatch))
        $outboxStateTransitionMs.Add((Convert-ElapsedMs $transitionStopwatch))
        $relayProcessingMs.Add((Convert-ElapsedMs $eventStopwatch))
        $timingLines.Add(
            "product_search_outbox_indexing_latency eventId=$($event.id) aggregateId=$($event.aggregateId) eventType=$($event.eventType) resultStatus=DONE queueWaitMs=$queueMs sourceDocumentLoadMs=$(Convert-ElapsedMs $sourceStopwatch) openSearchWriteMs=$(Convert-ElapsedMs $writeStopwatch) outboxStateTransitionMs=$(Convert-ElapsedMs $transitionStopwatch) relayProcessingMs=$(Convert-ElapsedMs $eventStopwatch)"
        )
        $claimedCount++
    }
}
$runStopwatch.Stop()

$measureSql = Get-Content -Raw $measureSqlPath
$lagJsonText = $measureSql | docker exec -i $PostgresContainer psql -U $PostgresUser -d $PostgresDatabase -v ON_ERROR_STOP=1 -q -t -A -v smoke_run=$RunId
if ($LASTEXITCODE -ne 0) {
    throw "measure-indexing-lag.sql failed"
}
$lagJson = (($lagJsonText -join "`n").Trim()) | ConvertFrom-Json

$summary = [ordered]@{
    runId = $RunId
    environment = "local synthetic / local PostgreSQL + OpenSearch smoke"
    eventCount = $EventCount
    claimedEvents = $claimedCount
    doneEvents = [int] $lagJson.statusCounts.doneCount
    failedEvents = [int] $lagJson.statusCounts.failedCount
    pendingCount = [int] $lagJson.statusCounts.pendingCount
    processingCount = [int] $lagJson.statusCounts.processingCount
    totalProcessingTimeMs = Convert-ElapsedMs $runStopwatch
    totalIndexingLagMs = $lagJson.totalIndexingLagMs
    breakdown = [ordered]@{
        queueWaitMs = Get-Percentiles $queueWaitMs.ToArray()
        sourceDocumentLoadMs = Get-Percentiles $sourceDocumentLoadMs.ToArray()
        openSearchWriteMs = Get-Percentiles $openSearchWriteMs.ToArray()
        outboxStateTransitionMs = Get-Percentiles $outboxStateTransitionMs.ToArray()
        relayProcessingMs = Get-Percentiles $relayProcessingMs.ToArray()
    }
    openSearchWriteDeleteCallCount = $writeCallCount
    relayTimingLogLineCount = $timingLines.Count
    indexName = $indexName
    writeAlias = $writeAlias
}

$summary | ConvertTo-Json -Depth 20 | Set-Content -Encoding UTF8 (Join-Path $resultDir "indexing-lag-summary.json")
$timingLines | Select-Object -First 20 | Set-Content -Encoding UTF8 (Join-Path $resultDir "relay-log-sample.txt")

$summaryMarkdown = @"
# Single-Document Indexing Baseline Summary

- Environment: local synthetic / local PostgreSQL + OpenSearch smoke
- Run id: $RunId
- Event count: $EventCount
- Claimed events: $claimedCount
- DONE events: $($summary.doneEvents)
- FAILED events: $($summary.failedEvents)
- Pending count: $($summary.pendingCount)
- Processing count: $($summary.processingCount)
- Total processing time ms: $($summary.totalProcessingTimeMs)
- OpenSearch write/delete call count: $writeCallCount
- Relay timing log line count: $($timingLines.Count)
- OpenSearch index: $indexName
- OpenSearch write alias: $writeAlias

## Total Indexing Lag Ms

| metric | value |
|---|---:|
| p50 | $($summary.totalIndexingLagMs.p50) |
| p95 | $($summary.totalIndexingLagMs.p95) |
| p99 | $($summary.totalIndexingLagMs.p99) |
| max | $($summary.totalIndexingLagMs.max) |

## Breakdown

| metric | p50 | p95 | p99 | max |
|---|---:|---:|---:|---:|
| queueWaitMs | $($summary.breakdown.queueWaitMs.p50) | $($summary.breakdown.queueWaitMs.p95) | $($summary.breakdown.queueWaitMs.p99) | $($summary.breakdown.queueWaitMs.max) |
| sourceDocumentLoadMs | $($summary.breakdown.sourceDocumentLoadMs.p50) | $($summary.breakdown.sourceDocumentLoadMs.p95) | $($summary.breakdown.sourceDocumentLoadMs.p99) | $($summary.breakdown.sourceDocumentLoadMs.max) |
| openSearchWriteMs | $($summary.breakdown.openSearchWriteMs.p50) | $($summary.breakdown.openSearchWriteMs.p95) | $($summary.breakdown.openSearchWriteMs.p99) | $($summary.breakdown.openSearchWriteMs.max) |
| outboxStateTransitionMs | $($summary.breakdown.outboxStateTransitionMs.p50) | $($summary.breakdown.outboxStateTransitionMs.p95) | $($summary.breakdown.outboxStateTransitionMs.p99) | $($summary.breakdown.outboxStateTransitionMs.max) |
| relayProcessingMs | $($summary.breakdown.relayProcessingMs.p50) | $($summary.breakdown.relayProcessingMs.p95) | $($summary.breakdown.relayProcessingMs.p99) | $($summary.breakdown.relayProcessingMs.max) |

## Notes

This is a local synthetic PostgreSQL + OpenSearch smoke measurement. It uses one OpenSearch document write per claimed outbox event. It is not Bulk Indexing, a k6 benchmark, or a production SLO/SLA claim.
"@
$summaryMarkdown | Set-Content -Encoding UTF8 (Join-Path $resultDir "summary.md")

if ($summary.doneEvents -ne $EventCount) {
    throw "Expected DONE events $EventCount, got $($summary.doneEvents)"
}
if ($summary.failedEvents -ne 0) {
    throw "Expected FAILED events 0, got $($summary.failedEvents)"
}
if ($writeCallCount -ne $EventCount) {
    throw "Expected OpenSearch write/delete call count $EventCount, got $writeCallCount"
}
if ($timingLines.Count -ne $EventCount) {
    throw "Expected timing line count $EventCount, got $($timingLines.Count)"
}

Write-Host "RUN_ID=$RunId"
Write-Host "RESULT_DIR=$resultDir"
Write-Host "DONE=$($summary.doneEvents) FAILED=$($summary.failedEvents)"
Write-Host "TOTAL_PROCESSING_TIME_MS=$($summary.totalProcessingTimeMs)"
Write-Host "P50_MS=$($summary.totalIndexingLagMs.p50) P95_MS=$($summary.totalIndexingLagMs.p95) P99_MS=$($summary.totalIndexingLagMs.p99) MAX_MS=$($summary.totalIndexingLagMs.max)"
Write-Host "WRITE_CALLS=$writeCallCount"
