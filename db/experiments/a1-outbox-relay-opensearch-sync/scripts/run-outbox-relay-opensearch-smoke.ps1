param(
    [string] $OpenSearchUrl = $env:OPENSEARCH_URL,
    [string] $OpenSearchImage = "opensearchproject/opensearch:2.15.0",
    [int] $BatchSize = 20,
    [int] $DoneRetentionDays = 7
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

if ([string]::IsNullOrWhiteSpace($OpenSearchUrl)) {
    $OpenSearchUrl = "http://localhost:9200"
}

$OpenSearchUrl = $OpenSearchUrl.TrimEnd("/")

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$experimentDir = Resolve-Path (Join-Path $scriptDir "..")
$repoRoot = Resolve-Path (Join-Path $experimentDir "..\..\..")
$mappingPath = Join-Path $repoRoot "db\experiments\a1-opensearch-index-mapping-alias\mappings\products_v1_nested.json"
$outboxSchemaPath = Join-Path $repoRoot "db\init\002_create_search_outbox.sql"
$productOptionsSchemaPath = Join-Path $repoRoot "db\seed\product-options\product_options_schema.sql"
$prepareSqlPath = Join-Path $experimentDir "sql\prepare-relay-smoke-events.sql"
$validateSqlPath = Join-Path $experimentDir "sql\validate-relay-smoke-results.sql"
$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$resultDir = Join-Path $experimentDir "results\$timestamp"

$indexName = "products_search_relay_smoke_v1"
$readAlias = "products_search_relay_smoke_read"
$writeAlias = "products_search_relay_smoke_write"
$currentAlias = "products_search_relay_smoke_current"
$smokeRun = "outbox-relay-opensearch-sync"
$failureSmokeRun = "outbox-relay-opensearch-sync-failure"
$cleanupSmokeRun = "outbox-relay-opensearch-sync-cleanup"

function Invoke-PsqlText {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Sql,
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

    $output = $Sql | docker @arguments
    if ($LASTEXITCODE -ne 0) {
        throw "psql failed with exit code $LASTEXITCODE"
    }

    return ($output -join "`n").Trim()
}

function Invoke-PsqlFile {
    param(
        [Parameter(Mandatory = $true)]
        [string] $SqlPath,
        [switch] $TuplesOnly
    )

    $sql = Get-Content -Raw $SqlPath
    return Invoke-PsqlText -Sql $sql -TuplesOnly:$TuplesOnly
}

function Invoke-OpenSearch {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Method,
        [Parameter(Mandatory = $true)]
        [string] $Path,
        [string] $BodyPath,
        [object] $Body,
        [string] $BaseUrl = $OpenSearchUrl
    )

    $uri = "$($BaseUrl.TrimEnd('/'))/$($Path.TrimStart('/'))"
    $params = @{
        Method = $Method
        Uri = $uri
    }

    if ($BodyPath) {
        $params["Body"] = Get-Content -Raw $BodyPath
        $params["ContentType"] = "application/json"
    }
    elseif ($null -ne $Body) {
        $params["Body"] = $Body | ConvertTo-Json -Depth 30
        $params["ContentType"] = "application/json"
    }

    Invoke-RestMethod @params
}

function Get-JsonLines {
    param([string] $Text)

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return @()
    }

    return @($Text -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object {
        $_ | ConvertFrom-Json
    })
}

function Set-OutboxDone {
    param([long] $EventId)

    $sql = @"
UPDATE search_outbox
SET
    status = 'DONE',
    retry_count = retry_count,
    last_error = NULL,
    updated_at = now(),
    processed_at = now()
WHERE id = $EventId;
"@
    Invoke-PsqlText -Sql $sql | Out-Null
}

function Set-OutboxFailed {
    param(
        [long] $EventId,
        [string] $ErrorMessage
    )

    $escaped = $ErrorMessage.Replace("'", "''")
    $sql = @"
UPDATE search_outbox
SET
    status = 'FAILED',
    retry_count = retry_count + 1,
    last_error = left('$escaped', 4000),
    updated_at = now(),
    processed_at = now()
WHERE id = $EventId;
"@
    Invoke-PsqlText -Sql $sql | Out-Null
}

function Claim-OutboxEvents {
    param([string] $TargetSmokeRun)

    $escapedSmokeRun = $TargetSmokeRun.Replace("'", "''")
    $sql = @"
BEGIN;
WITH claimed AS (
    SELECT id
    FROM search_outbox
    WHERE aggregate_type = 'PRODUCT'
      AND status = 'PENDING'
      AND payload->>'smokeRun' = '$escapedSmokeRun'
      AND (next_retry_at IS NULL OR next_retry_at <= now())
    ORDER BY id
    FOR UPDATE SKIP LOCKED
    LIMIT $BatchSize
),
updated AS (
    UPDATE search_outbox so
    SET
        status = 'PROCESSING',
        updated_at = now()
    FROM claimed
    WHERE so.id = claimed.id
    RETURNING jsonb_build_object(
        'id', so.id,
        'aggregateId', so.aggregate_id,
        'eventType', so.event_type,
        'retryCount', so.retry_count,
        'payload', so.payload
    )::TEXT AS event_json
)
SELECT event_json FROM updated ORDER BY (event_json::jsonb->>'id')::BIGINT;
COMMIT;
"@

    return Get-JsonLines -Text (Invoke-PsqlText -Sql $sql -TuplesOnly)
}

function Get-ProductDocument {
    param([long] $ProductId)

    $sql = @"
WITH product_document AS (
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
            ) FILTER (WHERE po.product_id IS NOT NULL),
            '[]'::jsonb
        )
    ) AS document
    FROM products p
    LEFT JOIN product_options_moderate_skew po
      ON po.product_id = p.id
    WHERE p.id = $ProductId
    GROUP BY
        p.id,
        p.seller_id,
        p.category_id,
        p.brand_id,
        p.status,
        p.price,
        p.rating,
        p.review_count,
        p.created_at,
        p.updated_at
)
SELECT document::TEXT FROM product_document;
"@

    $json = Invoke-PsqlText -Sql $sql -TuplesOnly
    if ([string]::IsNullOrWhiteSpace($json)) {
        return $null
    }

    return $json | ConvertFrom-Json
}

function Process-RelayBatch {
    param(
        [string] $TargetSmokeRun,
        [string] $TargetOpenSearchUrl = $OpenSearchUrl
    )

    $events = @(Claim-OutboxEvents -TargetSmokeRun $TargetSmokeRun)
    $processed = @()
    $failed = @()

    foreach ($event in $events) {
        $eventId = [long] $event.id
        $productId = [long] $event.aggregateId
        $eventType = [string] $event.eventType

        try {
            $document = Get-ProductDocument -ProductId $productId
            $operation = "upsert"

            if ($eventType -eq "PRODUCT_DELETED" -or ($null -ne $event.payload -and $event.payload.tombstone -eq $true)) {
                $operation = "delete"
            }
            elseif ($null -eq $document) {
                $operation = "delete"
            }
            elseif ($eventType -eq "PRODUCT_STATUS_CHANGED" -and $document.status -eq "DELETED") {
                $operation = "delete"
            }

            if ($operation -eq "delete") {
                try {
                    Invoke-OpenSearch -Method "DELETE" -Path "$writeAlias/_doc/${productId}?refresh=true" -BaseUrl $TargetOpenSearchUrl | Out-Null
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
            }
            else {
                Invoke-OpenSearch -Method "PUT" -Path "$writeAlias/_doc/${productId}?refresh=true" -Body $document -BaseUrl $TargetOpenSearchUrl | Out-Null
            }

            Set-OutboxDone -EventId $eventId
            $processed += [pscustomobject]@{
                eventId = $eventId
                productId = $productId
                eventType = $eventType
                operation = $operation
                status = "DONE"
            }
        }
        catch {
            Set-OutboxFailed -EventId $eventId -ErrorMessage $_.Exception.Message
            $failed += [pscustomobject]@{
                eventId = $eventId
                productId = $productId
                eventType = $eventType
                status = "FAILED"
                error = $_.Exception.Message
            }
        }
    }

    return [pscustomobject]@{
        claimedCount = $events.Count
        processed = $processed
        failed = $failed
    }
}

function Write-JsonFile {
    param(
        [Parameter(Mandatory = $true)]
        [object] $Value,
        [Parameter(Mandatory = $true)]
        [string] $Path
    )

    $Value | ConvertTo-Json -Depth 40 | Set-Content -Encoding UTF8 $Path
}

function Compare-FinalDocument {
    $source = Get-ProductDocument -ProductId -18002001
    $osDoc = Invoke-OpenSearch -Method "GET" -Path "$writeAlias/_doc/-18002001"
    $hitCount = (Invoke-OpenSearch -Method "POST" -Path "$writeAlias/_search" -Body @{
        query = @{
            term = @{
                productId = -18002001
            }
        }
    }).hits.total.value

    $mismatchCount = 0
    if ($osDoc._source.productId -ne $source.productId) { $mismatchCount++ }
    if ($osDoc._source.sellerId -ne $source.sellerId) { $mismatchCount++ }
    if ($osDoc._source.categoryId -ne $source.categoryId) { $mismatchCount++ }
    if ($osDoc._source.brandId -ne $source.brandId) { $mismatchCount++ }
    if ($osDoc._source.status -ne $source.status) { $mismatchCount++ }
    if ($osDoc._source.price -ne $source.price) { $mismatchCount++ }
    if ($osDoc._source.reviewCount -ne $source.reviewCount) { $mismatchCount++ }
    if ($osDoc._source.updatedAt -ne $source.updatedAt) { $mismatchCount++ }
    if ($osDoc._source.options.Count -ne $source.options.Count) { $mismatchCount++ }

    return [pscustomobject]@{
        productId = -18002001
        documentCount = [int] $hitCount
        duplicateReplayCount = [Math]::Max(0, [int] $hitCount - 1)
        idempotentReplayMismatchCount = $mismatchCount
        finalDocumentComparison = $(if ($mismatchCount -eq 0) { "pass" } else { "fail" })
        finalDocument = $osDoc._source
    }
}

function Add-StatusChangeEvent {
    $sql = @"
BEGIN;
UPDATE products
SET
    status = 'DELETED',
    updated_at = TIMESTAMP '2026-05-02 09:20:00'
WHERE id = -18002002;

INSERT INTO search_outbox (
    aggregate_type,
    aggregate_id,
    event_type,
    payload
)
VALUES (
    'PRODUCT',
    -18002002,
    'PRODUCT_STATUS_CHANGED',
    jsonb_build_object(
        'productId', -18002002,
        'eventType', 'PRODUCT_STATUS_CHANGED',
        'sourceUpdatedAt', '2026-05-02T09:20:00',
        'previousStatus', 'ACTIVE',
        'newStatus', 'DELETED',
        'tombstone', false,
        'smokeRun', '$smokeRun'
    )
);
COMMIT;
"@
    Invoke-PsqlText -Sql $sql | Out-Null
}

function Add-ReplayEvent {
    $sql = @"
INSERT INTO search_outbox (
    aggregate_type,
    aggregate_id,
    event_type,
    payload
)
VALUES (
    'PRODUCT',
    -18002001,
    'PRODUCT_UPDATED',
    jsonb_build_object(
        'productId', -18002001,
        'eventType', 'PRODUCT_UPDATED',
        'sourceUpdatedAt', '2026-05-02T09:10:00',
        'tombstone', false,
        'replay', true,
        'smokeRun', '$smokeRun'
    )
);
"@
    Invoke-PsqlText -Sql $sql | Out-Null
}

function Add-CleanupFixturesAndRunCleanup {
    $cutoffDays = $DoneRetentionDays
    $sql = @"
INSERT INTO search_outbox (
    aggregate_type,
    aggregate_id,
    event_type,
    payload,
    status,
    retry_count,
    last_error,
    created_at,
    updated_at,
    processed_at
)
VALUES
    (
        'PRODUCT',
        -18002901,
        'PRODUCT_UPDATED',
        jsonb_build_object('productId', -18002901, 'eventType', 'PRODUCT_UPDATED', 'smokeRun', '$cleanupSmokeRun', 'cleanupCase', 'oldDone'),
        'DONE',
        0,
        NULL,
        now() - INTERVAL '10 days',
        now() - INTERVAL '10 days',
        now() - INTERVAL '10 days'
    ),
    (
        'PRODUCT',
        -18002902,
        'PRODUCT_UPDATED',
        jsonb_build_object('productId', -18002902, 'eventType', 'PRODUCT_UPDATED', 'smokeRun', '$cleanupSmokeRun', 'cleanupCase', 'recentDone'),
        'DONE',
        0,
        NULL,
        now(),
        now(),
        now()
    ),
    (
        'PRODUCT',
        -18002903,
        'PRODUCT_UPDATED',
        jsonb_build_object('productId', -18002903, 'eventType', 'PRODUCT_UPDATED', 'smokeRun', '$cleanupSmokeRun', 'cleanupCase', 'failed'),
        'FAILED',
        1,
        'retained failure fixture',
        now() - INTERVAL '10 days',
        now() - INTERVAL '10 days',
        now() - INTERVAL '10 days'
    ),
    (
        'PRODUCT',
        -18002904,
        'PRODUCT_UPDATED',
        jsonb_build_object('productId', -18002904, 'eventType', 'PRODUCT_UPDATED', 'smokeRun', '$cleanupSmokeRun', 'cleanupCase', 'pending'),
        'PENDING',
        0,
        NULL,
        now() - INTERVAL '10 days',
        now() - INTERVAL '10 days',
        NULL
    );

DROP TABLE IF EXISTS pg_temp.relay_cleanup_result;
CREATE TEMP TABLE relay_cleanup_result AS
WITH deleted AS (
    DELETE FROM search_outbox
    WHERE status = 'DONE'
      AND payload->>'smokeRun' = '$cleanupSmokeRun'
      AND processed_at < now() - ($cutoffDays::TEXT || ' days')::INTERVAL
    RETURNING id
)
SELECT COUNT(*) AS cleaned_done_event_count
FROM deleted;

SELECT jsonb_build_object(
    'doneRetentionDays', $cutoffDays,
    'cleanedDoneEventCount', (SELECT cleaned_done_event_count FROM relay_cleanup_result),
    'retainedRecentDoneCount', (
        SELECT COUNT(*) FROM search_outbox
        WHERE status = 'DONE'
          AND payload->>'smokeRun' = '$cleanupSmokeRun'
    ),
    'retainedFailedCount', (
        SELECT COUNT(*) FROM search_outbox
        WHERE status = 'FAILED'
          AND payload->>'smokeRun' = '$cleanupSmokeRun'
    ),
    'retainedPendingCount', (
        SELECT COUNT(*) FROM search_outbox
        WHERE status = 'PENDING'
          AND payload->>'smokeRun' = '$cleanupSmokeRun'
    )
)::TEXT;
"@

    return Invoke-PsqlText -Sql $sql -TuplesOnly | ConvertFrom-Json
}

Push-Location $repoRoot
try {
    Write-Host "Checking OpenSearch health at $OpenSearchUrl"
    $health = Invoke-OpenSearch -Method "GET" -Path "_cluster/health"

    Write-Host "Applying PostgreSQL relay smoke schemas"
    Invoke-PsqlFile -SqlPath $outboxSchemaPath | Out-Null
    Invoke-PsqlFile -SqlPath $productOptionsSchemaPath | Out-Null

    Write-Host "Preparing PostgreSQL smoke data"
    $prepareResult = Invoke-PsqlFile -SqlPath $prepareSqlPath -TuplesOnly | ConvertFrom-Json

    Write-Host "Resetting relay smoke OpenSearch index"
    try {
        Invoke-OpenSearch -Method "DELETE" -Path $indexName | Out-Null
    }
    catch {
        $statusCode = $_.Exception.Response.StatusCode.value__
        if ($statusCode -ne 404) {
            throw
        }
    }

    $indexCreate = Invoke-OpenSearch -Method "PUT" -Path $indexName -BodyPath $mappingPath
    $aliasCreate = Invoke-OpenSearch -Method "POST" -Path "_aliases" -Body @{
        actions = @(
            @{ add = @{ index = $indexName; alias = $readAlias } },
            @{ add = @{ index = $indexName; alias = $writeAlias } },
            @{ add = @{ index = $indexName; alias = $currentAlias } }
        )
    }

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    Write-Host "Processing initial relay batch"
    $initialRelay = Process-RelayBatch -TargetSmokeRun $smokeRun

    Write-Host "Adding and processing status-change delete event"
    Add-StatusChangeEvent
    $statusChangeRelay = Process-RelayBatch -TargetSmokeRun $smokeRun

    Write-Host "Adding and processing idempotent replay event"
    Add-ReplayEvent
    $replayRelay = Process-RelayBatch -TargetSmokeRun $smokeRun
    $stopwatch.Stop()

    Write-Host "Running failure scenario"
    $failureRelay = Process-RelayBatch -TargetSmokeRun $failureSmokeRun -TargetOpenSearchUrl "http://127.0.0.1:1"

    Write-Host "Running cleanup retention scenario"
    $cleanupResult = Add-CleanupFixturesAndRunCleanup

    $finalDocumentResult = Compare-FinalDocument
    $deletedDocSearch = Invoke-OpenSearch -Method "POST" -Path "$writeAlias/_search" -Body @{
        query = @{
            term = @{
                productId = -18002002
            }
        }
    }
    $deleteResult = [pscustomobject]@{
        productId = -18002002
        sourceStatus = "DELETED"
        behavior = "delete"
        documentCount = [int] $deletedDocSearch.hits.total.value
        result = $(if ([int] $deletedDocSearch.hits.total.value -eq 0) { "pass" } else { "fail" })
    }

    $dbValidation = Invoke-PsqlFile -SqlPath $validateSqlPath -TuplesOnly | ConvertFrom-Json

    $processedEventCount = @($initialRelay.processed).Count + @($statusChangeRelay.processed).Count + @($replayRelay.processed).Count
    $failedEventCount = @($failureRelay.failed).Count
    $retryCount = [int] $dbValidation.failureScenarioRetryCount

    $relayProcessingResult = [pscustomobject]@{
        initial = $initialRelay
        statusChange = $statusChangeRelay
        replay = $replayRelay
        processedEventCount = $processedEventCount
        relayBatchDurationMs = $stopwatch.ElapsedMilliseconds
    }

    $idempotentReplayResult = [pscustomobject]@{
        productId = -18002001
        duplicateReplayCount = $finalDocumentResult.duplicateReplayCount
        idempotentReplayMismatchCount = $finalDocumentResult.idempotentReplayMismatchCount
        finalDocumentComparison = $finalDocumentResult.finalDocumentComparison
    }

    if ($processedEventCount -ne 5) {
        throw "Expected processed event count 5, got $processedEventCount"
    }
    if ([int] $dbValidation.relayPendingEventCount -ne 0) {
        throw "Expected relay pending event count 0, got $($dbValidation.relayPendingEventCount)"
    }
    if ($failedEventCount -ne 1) {
        throw "Expected failed event count 1, got $failedEventCount"
    }
    if ($retryCount -ne 1) {
        throw "Expected retry count 1, got $retryCount"
    }
    if ([int] $dbValidation.failureScenarioLastErrorCount -ne 1) {
        throw "Expected failed last_error count 1, got $($dbValidation.failureScenarioLastErrorCount)"
    }
    if ($finalDocumentResult.idempotentReplayMismatchCount -ne 0) {
        throw "Expected final document mismatch count 0, got $($finalDocumentResult.idempotentReplayMismatchCount)"
    }
    if ($finalDocumentResult.duplicateReplayCount -ne 0) {
        throw "Expected duplicate replay count 0, got $($finalDocumentResult.duplicateReplayCount)"
    }
    if ($deleteResult.documentCount -ne 0) {
        throw "Expected deleted status-change document count 0, got $($deleteResult.documentCount)"
    }
    if ([int] $cleanupResult.cleanedDoneEventCount -ne 1) {
        throw "Expected cleaned DONE event count 1, got $($cleanupResult.cleanedDoneEventCount)"
    }
    if ([int] $cleanupResult.retainedFailedCount -ne 1) {
        throw "Expected retained FAILED cleanup count 1, got $($cleanupResult.retainedFailedCount)"
    }
    if ([int] $cleanupResult.retainedRecentDoneCount -ne 1) {
        throw "Expected retained recent DONE count 1, got $($cleanupResult.retainedRecentDoneCount)"
    }
    if ([int] $cleanupResult.retainedPendingCount -ne 1) {
        throw "Expected retained PENDING count 1, got $($cleanupResult.retainedPendingCount)"
    }

    New-Item -ItemType Directory -Force -Path $resultDir | Out-Null

    $counts = [pscustomobject]@{
        processedEventCount = $processedEventCount
        pendingEventCount = [int] $dbValidation.relayPendingEventCount
        failedEventCount = $failedEventCount
        retryCount = $retryCount
        oldestPendingAgeSeconds = $dbValidation.oldestPendingAgeSeconds
        relayBatchDurationMs = $stopwatch.ElapsedMilliseconds
    }

    $upsertResult = [pscustomobject]@{
        indexName = $indexName
        writeAlias = $writeAlias
        indexCreate = $indexCreate
        aliasCreate = $aliasCreate
        health = $health
    }

    $summary = @"
# Outbox Relay OpenSearch Smoke Summary

- PostgreSQL target: docker compose postgres/readpath_lab
- OpenSearch URL: $OpenSearchUrl
- OpenSearch image: $OpenSearchImage
- Smoke index: $indexName
- Write alias: $writeAlias
- Final smoke status: pass

| metric | value |
|---|---:|
| processed event count | $processedEventCount |
| pending event count | $($counts.pendingEventCount) |
| failed event count | $failedEventCount |
| retry count | $retryCount |
| relay batch duration ms | $($stopwatch.ElapsedMilliseconds) |
| idempotent replay mismatch count | $($finalDocumentResult.idempotentReplayMismatchCount) |
| duplicate replay count | $($finalDocumentResult.duplicateReplayCount) |
| status-change deleted document count | $($deleteResult.documentCount) |
| cleaned old DONE event count | $($cleanupResult.cleanedDoneEventCount) |
| retained FAILED cleanup count | $($cleanupResult.retainedFailedCount) |
| retained recent DONE count | $($cleanupResult.retainedRecentDoneCount) |
| retained PENDING count | $($cleanupResult.retainedPendingCount) |

Final document comparison result: $($finalDocumentResult.finalDocumentComparison)

Status-change behavior: source status DELETED deletes the OpenSearch document.

This smoke result is not a benchmark or production readiness claim.
"@

    Write-JsonFile -Value $relayProcessingResult -Path (Join-Path $resultDir "relay-processing-result.json")
    Write-JsonFile -Value $upsertResult -Path (Join-Path $resultDir "opensearch-upsert-result.json")
    Write-JsonFile -Value $finalDocumentResult -Path (Join-Path $resultDir "final-document-result.json")
    Write-JsonFile -Value $idempotentReplayResult -Path (Join-Path $resultDir "idempotent-replay-result.json")
    Write-JsonFile -Value $deleteResult -Path (Join-Path $resultDir "delete-status-change-result.json")
    Write-JsonFile -Value $failureRelay -Path (Join-Path $resultDir "failure-scenario-result.json")
    Write-JsonFile -Value $cleanupResult -Path (Join-Path $resultDir "cleanup-retention-result.json")
    Write-JsonFile -Value $counts -Path (Join-Path $resultDir "pending-processed-failed-counts.json")
    $summary | Set-Content -Encoding UTF8 (Join-Path $resultDir "outbox-relay-summary.md")

    Write-Host "PASS: outbox relay OpenSearch smoke validation completed"
    Write-Host "Result artifacts: $resultDir"
} finally {
    Pop-Location
}
