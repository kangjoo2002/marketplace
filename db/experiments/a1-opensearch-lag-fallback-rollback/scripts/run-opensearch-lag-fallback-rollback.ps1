param(
    [string] $OpenSearchUrl = $env:OPENSEARCH_URL,
    [string] $OpenSearchImage = "opensearchproject/opensearch:2.15.0",
    [int] $BatchSize = 20,
    [double] $LagP95ThresholdSeconds = $(if ($env:OPS_LAG_P95_THRESHOLD_SECONDS) { [double] $env:OPS_LAG_P95_THRESHOLD_SECONDS } else { 30 }),
    [double] $LagMaxThresholdSeconds = $(if ($env:OPS_LAG_MAX_THRESHOLD_SECONDS) { [double] $env:OPS_LAG_MAX_THRESHOLD_SECONDS } else { 60 }),
    [int] $OpenSearchHealthWaitSeconds = $(if ($env:OPS_OPEN_SEARCH_HEALTH_WAIT_SECONDS) { [int] $env:OPS_OPEN_SEARCH_HEALTH_WAIT_SECONDS } else { 120 }),
    [int] $PostgresReadyWaitSeconds = $(if ($env:OPS_POSTGRES_READY_WAIT_SECONDS) { [int] $env:OPS_POSTGRES_READY_WAIT_SECONDS } else { 120 }),
    [int] $BacklogDelaySeconds = $(if ($env:OPS_BACKLOG_DELAY_SECONDS) { [int] $env:OPS_BACKLOG_DELAY_SECONDS } else { 2 })
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
$prepareSqlPath = Join-Path $experimentDir "sql\prepare-lag-smoke-events.sql"
$validateSqlPath = Join-Path $experimentDir "sql\validate-lag-results.sql"
$runbookPath = Join-Path $experimentDir "runbooks\reindex-recovery-runbook.md"
$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$tempResultDir = Join-Path $experimentDir "results\$timestamp.partial"
$resultDir = Join-Path $experimentDir "results\$timestamp"

$v1Index = "products_search_ops_smoke_v1"
$v2Index = "products_search_ops_smoke_v2"
$readAlias = "products_search_ops_smoke_read"
$writeAlias = "products_search_ops_smoke_write"
$currentAlias = "products_search_ops_smoke_current"
$normalSmokeRun = "opensearch-lag-fallback-rollback-normal"
$backlogSmokeRun = "opensearch-lag-fallback-rollback-backlog"
$normalProductIds = @(-21002001, -21002002, -21002003, -21002004, -21002005)
$backlogProductIds = @(-21002011, -21002012, -21002013)
$v1MarkerId = -21009901
$v2MarkerId = -21009902

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

function Wait-PostgresReady {
    $lastOutput = $null
    $deadline = (Get-Date).AddSeconds($PostgresReadyWaitSeconds)
    while ((Get-Date) -lt $deadline) {
        $output = docker compose exec -T postgres pg_isready -U readpath -d readpath_lab 2>&1
        $lastOutput = ($output -join "`n").Trim()
        if ($LASTEXITCODE -eq 0) {
            return [pscustomobject]@{
                ready = $true
                waitSeconds = $PostgresReadyWaitSeconds
                output = $lastOutput
            }
        }
        Start-Sleep -Seconds 2
    }

    throw "PostgreSQL readiness check did not succeed within $PostgresReadyWaitSeconds seconds. Last output: $lastOutput"
}

function Invoke-OpenSearch {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Method,
        [Parameter(Mandatory = $true)]
        [string] $Path,
        [string] $BodyPath,
        [object] $Body,
        [string] $ContentType = "application/json"
    )

    $uri = "$OpenSearchUrl/$($Path.TrimStart('/'))"
    $params = @{
        Method = $Method
        Uri = $uri
    }

    if ($BodyPath) {
        $params["Body"] = Get-Content -Raw $BodyPath
        $params["ContentType"] = $ContentType
    }
    elseif ($null -ne $Body) {
        if ($Body -is [string]) {
            $params["Body"] = $Body
        }
        else {
            $params["Body"] = $Body | ConvertTo-Json -Depth 70 -Compress
        }
        $params["ContentType"] = $ContentType
    }

    Invoke-RestMethod @params
}

function Wait-OpenSearchHealth {
    $lastError = $null
    $deadline = (Get-Date).AddSeconds($OpenSearchHealthWaitSeconds)
    while ((Get-Date) -lt $deadline) {
        try {
            $health = Invoke-OpenSearch -Method "GET" -Path "_cluster/health"
            return [pscustomobject]@{
                ready = $true
                waitSeconds = $OpenSearchHealthWaitSeconds
                health = $health
            }
        }
        catch {
            $lastError = $_.Exception.Message
            Start-Sleep -Seconds 2
        }
    }

    throw "OpenSearch healthcheck did not succeed within $OpenSearchHealthWaitSeconds seconds. Last error: $lastError"
}

function Write-JsonFile {
    param(
        [Parameter(Mandatory = $true)]
        [object] $Value,
        [Parameter(Mandatory = $true)]
        [string] $Path
    )

    $Value | ConvertTo-Json -Depth 80 | Set-Content -Encoding UTF8 $Path
}

function Remove-SmokeIndex {
    param([string] $IndexName)

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
}

function New-MarkerDocument {
    param(
        [long] $ProductId,
        [int] $ReviewCount
    )

    return @{
        productId = $ProductId
        sellerId = 21099
        categoryId = 75
        brandId = 943
        status = "ACTIVE"
        price = 19900
        rating = 4.50
        reviewCount = $ReviewCount
        createdAt = "2026-05-02T15:09:00"
        updatedAt = "2026-05-02T15:09:00"
        sourceUpdatedAt = "2026-05-02T15:09:00"
        documentRefreshedAt = "2026-05-02T15:09:00"
        options = @(
            @{
                color = "BLACK"
                size = "M"
                stockStatus = "IN_STOCK"
            }
        )
    }
}

function Test-DocumentExists {
    param(
        [string] $Target,
        [long] $ProductId
    )

    try {
        Invoke-OpenSearch -Method "GET" -Path "$Target/_doc/$ProductId" | Out-Null
        return $true
    }
    catch {
        $statusCode = $null
        if ($null -ne $_.Exception.Response) {
            $statusCode = $_.Exception.Response.StatusCode.value__
        }
        if ($statusCode -eq 404) {
            return $false
        }
        throw
    }
}

function Test-IndexExists {
    param([string] $IndexName)

    try {
        Invoke-OpenSearch -Method "GET" -Path $IndexName | Out-Null
        return $true
    }
    catch {
        $statusCode = $null
        if ($null -ne $_.Exception.Response) {
            $statusCode = $_.Exception.Response.StatusCode.value__
        }
        if ($statusCode -eq 404) {
            return $false
        }
        throw
    }
}

function Initialize-SmokeIndexes {
    Remove-SmokeIndex -IndexName $v1Index
    Remove-SmokeIndex -IndexName $v2Index

    $v1Create = Invoke-OpenSearch -Method "PUT" -Path $v1Index -BodyPath $mappingPath
    $v2Create = Invoke-OpenSearch -Method "PUT" -Path $v2Index -BodyPath $mappingPath

    Invoke-OpenSearch -Method "PUT" -Path "$v1Index/_doc/${v1MarkerId}?refresh=true" -Body (New-MarkerDocument -ProductId $v1MarkerId -ReviewCount 901) | Out-Null
    Invoke-OpenSearch -Method "PUT" -Path "$v2Index/_doc/${v2MarkerId}?refresh=true" -Body (New-MarkerDocument -ProductId $v2MarkerId -ReviewCount 902) | Out-Null

    $aliasCreate = Invoke-OpenSearch -Method "POST" -Path "_aliases" -Body @{
        actions = @(
            @{ add = @{ index = $v1Index; alias = $readAlias } },
            @{ add = @{ index = $v1Index; alias = $writeAlias } },
            @{ add = @{ index = $v1Index; alias = $currentAlias } }
        )
    }

    return [pscustomobject]@{
        v1IndexCreate = $v1Create
        v2IndexCreate = $v2Create
        aliasCreate = $aliasCreate
        writeAliasBehavior = "write alias remains on v1 during this operations smoke; read/current aliases are switched and rolled back in isolation"
    }
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

function Add-OutboxEvents {
    param(
        [string] $SmokeRun,
        [long[]] $ProductIds
    )

    $escapedSmokeRun = $SmokeRun.Replace("'", "''")
    $values = @($ProductIds | ForEach-Object {
        "('PRODUCT', $_, 'PRODUCT_UPDATED', jsonb_build_object('productId', $_, 'eventType', 'PRODUCT_UPDATED', 'smokeRun', '$escapedSmokeRun', 'tombstone', false), now(), now())"
    }) -join ",`n"

    $sql = @"
INSERT INTO search_outbox (
    aggregate_type,
    aggregate_id,
    event_type,
    payload,
    created_at,
    updated_at
)
VALUES
$values
RETURNING jsonb_build_object(
    'id', id,
    'aggregateId', aggregate_id,
    'createdAt', created_at,
    'smokeRun', payload->>'smokeRun'
)::TEXT;
"@

    $text = Invoke-PsqlText -Sql $sql -TuplesOnly
    if ([string]::IsNullOrWhiteSpace($text)) {
        return @()
    }
    return @($text -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_ | ConvertFrom-Json })
}

function Claim-OutboxEvents {
    param([string] $SmokeRun)

    $escapedSmokeRun = $SmokeRun.Replace("'", "''")
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
        'payload', so.payload
    )::TEXT AS event_json
)
SELECT event_json FROM updated ORDER BY (event_json::jsonb->>'id')::BIGINT;
COMMIT;
"@

    $text = Invoke-PsqlText -Sql $sql -TuplesOnly
    if ([string]::IsNullOrWhiteSpace($text)) {
        return @()
    }
    return @($text -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_ | ConvertFrom-Json })
}

function Set-OutboxDone {
    param([long] $EventId)

    $sql = @"
UPDATE search_outbox
SET
    status = 'DONE',
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

function Invoke-RelayUntilDrained {
    param([string] $SmokeRun)

    $processed = @()
    $failed = @()
    $batchCount = 0

    while ($true) {
        $events = @(Claim-OutboxEvents -SmokeRun $SmokeRun)
        if ($events.Count -eq 0) {
            break
        }
        $batchCount++

        foreach ($event in $events) {
            $eventId = [long] $event.id
            $productId = [long] $event.aggregateId
            $eventType = [string] $event.eventType

            try {
                $document = Get-ProductDocument -ProductId $productId
                if ($null -eq $document) {
                    Invoke-OpenSearch -Method "DELETE" -Path "$writeAlias/_doc/${productId}?refresh=true" | Out-Null
                    $operation = "delete"
                }
                else {
                    Invoke-OpenSearch -Method "PUT" -Path "$writeAlias/_doc/${productId}?refresh=true" -Body $document | Out-Null
                    $operation = "upsert"
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
    }

    return [pscustomobject]@{
        batchCount = $batchCount
        processed = $processed
        failed = $failed
    }
}

function Get-PendingMetrics {
    param([string] $SmokeRun)

    $escapedSmokeRun = $SmokeRun.Replace("'", "''")
    $sql = @"
WITH scoped AS (
    SELECT *
    FROM search_outbox
    WHERE payload->>'smokeRun' = '$escapedSmokeRun'
)
SELECT jsonb_build_object(
    'pendingEventCount', COUNT(*) FILTER (WHERE status = 'PENDING'),
    'oldestPendingAgeSeconds', COALESCE(
        MAX(EXTRACT(EPOCH FROM (now() - created_at))) FILTER (WHERE status = 'PENDING'),
        0
    ),
    'failedEventCount', COUNT(*) FILTER (WHERE status = 'FAILED')
)::TEXT
FROM scoped;
"@

    return Invoke-PsqlText -Sql $sql -TuplesOnly | ConvertFrom-Json
}

function Get-LagMetrics {
    $dbValidation = Invoke-PsqlFile -SqlPath $validateSqlPath -TuplesOnly | ConvertFrom-Json

    $p95 = [double] $dbValidation.normalP95EventLagSeconds
    $max = [double] $dbValidation.normalMaxEventLagSeconds
    $failed = [int] $dbValidation.normalFailedEventCount
    $thresholdPassed = ($p95 -le $LagP95ThresholdSeconds) -and ($max -le $LagMaxThresholdSeconds) -and ($failed -eq 0)

    return [pscustomobject]@{
        p95EventLagSeconds = $p95
        p95EventLagThresholdSeconds = $LagP95ThresholdSeconds
        maxEventLagSeconds = $max
        maxEventLagThresholdSeconds = $LagMaxThresholdSeconds
        processedEventCount = [int] $dbValidation.normalProcessedEventCount
        failedEventCount = $failed
        retryCount = [int] $dbValidation.normalRetryCount
        lagThresholdResult = $(if ($thresholdPassed) { "pass" } else { "fail" })
        rawValidation = $dbValidation
    }
}

function Switch-ReadAliasesToV2 {
    Invoke-OpenSearch -Method "POST" -Path "_aliases" -Body @{
        actions = @(
            @{ remove = @{ index = $v1Index; alias = $readAlias } },
            @{ remove = @{ index = $v1Index; alias = $currentAlias } },
            @{ add = @{ index = $v2Index; alias = $readAlias } },
            @{ add = @{ index = $v2Index; alias = $currentAlias } }
        )
    } | Out-Null
}

function Rollback-ReadAliasesToV1 {
    Invoke-OpenSearch -Method "POST" -Path "_aliases" -Body @{
        actions = @(
            @{ remove = @{ index = $v2Index; alias = $readAlias } },
            @{ remove = @{ index = $v2Index; alias = $currentAlias } },
            @{ add = @{ index = $v1Index; alias = $readAlias } },
            @{ add = @{ index = $v1Index; alias = $currentAlias } }
        )
    } | Out-Null
}

Push-Location $repoRoot
$success = $false
try {
    Write-Host "Checking PostgreSQL readiness"
    $postgresReady = Wait-PostgresReady

    Write-Host "Checking OpenSearch health at $OpenSearchUrl"
    $openSearchReady = Wait-OpenSearchHealth

    New-Item -ItemType Directory -Force -Path $tempResultDir | Out-Null

    Write-Host "Applying PostgreSQL smoke schemas"
    Invoke-PsqlFile -SqlPath $outboxSchemaPath | Out-Null
    Invoke-PsqlFile -SqlPath $productOptionsSchemaPath | Out-Null

    Write-Host "Preparing controlled source rows"
    $prepareResult = Invoke-PsqlFile -SqlPath $prepareSqlPath -TuplesOnly | ConvertFrom-Json

    Write-Host "Creating isolated OpenSearch ops smoke indexes and aliases"
    $indexSetup = Initialize-SmokeIndexes

    $measurementStartedAt = (Get-Date).ToString("o")
    Write-Host "Creating normal lag measurement events"
    $normalEvents = @(Add-OutboxEvents -SmokeRun $normalSmokeRun -ProductIds $normalProductIds)

    Write-Host "Processing normal lag measurement events"
    $normalRelay = Invoke-RelayUntilDrained -SmokeRun $normalSmokeRun
    $measurementFinishedAt = (Get-Date).ToString("o")

    Write-Host "Creating controlled backlog events"
    $backlogEvents = @(Add-OutboxEvents -SmokeRun $backlogSmokeRun -ProductIds $backlogProductIds)
    if ($BacklogDelaySeconds -gt 0) {
        Start-Sleep -Seconds $BacklogDelaySeconds
    }
    $backlogBefore = Get-PendingMetrics -SmokeRun $backlogSmokeRun

    Write-Host "Recovering controlled backlog"
    $backlogRelay = Invoke-RelayUntilDrained -SmokeRun $backlogSmokeRun
    $backlogAfter = Get-PendingMetrics -SmokeRun $backlogSmokeRun
    $lagMetrics = Get-LagMetrics

    $backlogThresholdPassed =
        ([int] $backlogAfter.pendingEventCount -eq 0) -and
        ([double] $backlogAfter.oldestPendingAgeSeconds -eq 0) -and
        ([int] $backlogAfter.failedEventCount -eq 0)

    Write-Host "Running alias switch smoke"
    $initialReadAliasV1 = Test-DocumentExists -Target $readAlias -ProductId $v1MarkerId
    Switch-ReadAliasesToV2
    $readAliasSeesV2 = Test-DocumentExists -Target $readAlias -ProductId $v2MarkerId
    $readAliasStillSeesV1AfterSwitch = Test-DocumentExists -Target $readAlias -ProductId $v1MarkerId

    Write-Host "Running alias rollback smoke"
    $rollbackStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    Rollback-ReadAliasesToV1
    $readAliasSeesV1AfterRollback = Test-DocumentExists -Target $readAlias -ProductId $v1MarkerId
    $rollbackStopwatch.Stop()
    $readAliasStillSeesV2AfterRollback = Test-DocumentExists -Target $readAlias -ProductId $v2MarkerId

    $previousIndexRetained = (Test-IndexExists -IndexName $v1Index) -and (Test-IndexExists -IndexName $v2Index)
    $aliasSwitchSuccess = $initialReadAliasV1 -and $readAliasSeesV2 -and (-not $readAliasStillSeesV1AfterSwitch)
    $rollbackSuccess = $readAliasSeesV1AfterRollback -and (-not $readAliasStillSeesV2AfterRollback)

    $fallbackRequirements = [pscustomobject]@{
        fallbackRequirementDefined = $true
        openSearchTimeoutScenarioDefined = $true
        openSearch5xxScenarioDefined = $true
        connectionRefusedScenarioDefined = $true
        connectionResetScenarioDefined = $true
        hostUnreachableScenarioDefined = $true
        dnsFailureScenarioDefined = $true
        circuitBreakerScenarioDefined = $true
        invalidSearchResponseScenarioDefined = $true
        nonFallbackClientErrorConditionsDefined = $true
        implementedApplicationFallback = $false
        fallbackTriggers = @(
            "OpenSearch request timeout",
            "OpenSearch HTTP 5xx",
            "connection refused",
            "connection reset",
            "host unreachable",
            "DNS failure",
            "circuit breaker open",
            "malformed or invalid Search response"
        )
        nonFallbackConditions = @(
            "request validation error",
            "unsupported query parameter",
            "client-side 4xx caused by invalid input"
        )
    }

    $measurementControl = [pscustomobject]@{
        postgresReadyBeforeEventCreation = [bool] $postgresReady.ready
        openSearchHealthyBeforeEventCreation = [bool] $openSearchReady.ready
        eventCreationStartedAfterReadiness = $true
        dockerStartupTimeIncludedInEventLag = $false
        openSearchHealthWaitIncludedInEventLag = $false
        normalLagSeparatedFromBacklogRecovery = $true
        controlledBacklogExcludedFromNormalLagMetrics = $true
        measurementStartedAt = $measurementStartedAt
        measurementFinishedAt = $measurementFinishedAt
        postgresReadiness = $postgresReady
        openSearchReadiness = $openSearchReady
        environmentCaveat = "local Docker Compose PostgreSQL and experiment-local OpenSearch smoke service only"
        thresholdCaveat = "local smoke validation gates only; not production SLA/SLO"
    }

    $backlogRecovery = [pscustomobject]@{
        pendingEventCountBeforeRecovery = [int] $backlogBefore.pendingEventCount
        pendingEventCountAfterRecovery = [int] $backlogAfter.pendingEventCount
        pendingEventCountThresholdAfterRecovery = 0
        oldestPendingAgeSecondsBeforeRecovery = [double] $backlogBefore.oldestPendingAgeSeconds
        oldestPendingAgeSecondsAfterRecovery = [double] $backlogAfter.oldestPendingAgeSeconds
        oldestPendingAgeThresholdSecondsAfterRecovery = 0
        failedEventCountAfterRecovery = [int] $backlogAfter.failedEventCount
        failedEventCountThresholdAfterRecovery = 0
        processedBacklogEventCount = @($backlogRelay.processed).Count
        recoveryThresholdResult = $(if ($backlogThresholdPassed) { "pass" } else { "fail" })
        backlogDelaySeconds = $BacklogDelaySeconds
        note = "controlled backlog data is excluded from normal p95/max event lag"
    }

    $aliasSwitchResult = [pscustomobject]@{
        v1Index = $v1Index
        v2Index = $v2Index
        readAlias = $readAlias
        currentAlias = $currentAlias
        writeAlias = $writeAlias
        writeAliasBehavior = $indexSetup.writeAliasBehavior
        initialReadAliasSeesV1Marker = $initialReadAliasV1
        readAliasSeesV2MarkerAfterSwitch = $readAliasSeesV2
        readAliasStillSeesV1MarkerAfterSwitch = $readAliasStillSeesV1AfterSwitch
        aliasSwitchSuccess = $aliasSwitchSuccess
    }

    $aliasRollbackResult = [pscustomobject]@{
        rollbackSuccess = $rollbackSuccess
        rollbackDurationMs = $rollbackStopwatch.ElapsedMilliseconds
        readAliasSeesV1MarkerAfterRollback = $readAliasSeesV1AfterRollback
        readAliasStillSeesV2MarkerAfterRollback = $readAliasStillSeesV2AfterRollback
        previousIndexRetained = $previousIndexRetained
        retainedIndexes = @($v1Index, $v2Index)
    }

    $reindexRunbookResult = [pscustomobject]@{
        reindexRunbookDocumented = (Test-Path $runbookPath)
        previousIndexRetentionPolicyDocumented = (Select-String -LiteralPath $runbookPath -Pattern "previous index" -Quiet)
        runbookPath = $runbookPath
    }

    Write-JsonFile -Value $measurementControl -Path (Join-Path $tempResultDir "measurement-control-result.json")
    Write-JsonFile -Value $lagMetrics -Path (Join-Path $tempResultDir "lag-metrics-result.json")
    Write-JsonFile -Value $backlogRecovery -Path (Join-Path $tempResultDir "backlog-recovery-result.json")
    Write-JsonFile -Value $fallbackRequirements -Path (Join-Path $tempResultDir "fallback-requirements-result.json")
    Write-JsonFile -Value $aliasSwitchResult -Path (Join-Path $tempResultDir "alias-switch-result.json")
    Write-JsonFile -Value $aliasRollbackResult -Path (Join-Path $tempResultDir "alias-rollback-result.json")
    Write-JsonFile -Value $reindexRunbookResult -Path (Join-Path $tempResultDir "reindex-runbook-result.json")

    if (@($normalEvents).Count -ne 5) { throw "Expected 5 normal lag events, got $(@($normalEvents).Count)" }
    if (@($normalRelay.failed).Count -ne 0) { throw "Expected normal relay failed count 0, got $(@($normalRelay.failed).Count)" }
    if ($lagMetrics.lagThresholdResult -ne "pass") { throw "Lag threshold result was $($lagMetrics.lagThresholdResult)" }
    if (-not $backlogThresholdPassed) { throw "Backlog recovery thresholds did not pass" }
    if (-not $aliasSwitchSuccess) { throw "Alias switch smoke did not pass" }
    if (-not $rollbackSuccess) { throw "Alias rollback smoke did not pass" }
    if (-not $previousIndexRetained) { throw "Expected both smoke indexes to be retained after rollback" }
    if (-not $reindexRunbookResult.reindexRunbookDocumented) { throw "Reindex recovery runbook was not found" }
    if (-not $reindexRunbookResult.previousIndexRetentionPolicyDocumented) { throw "Previous index retention policy was not found in the runbook" }

    $summary = @"
# OpenSearch Lag Fallback Rollback Operations Smoke Summary

- PostgreSQL target: docker compose postgres/readpath_lab
- OpenSearch URL: $OpenSearchUrl
- OpenSearch image: $OpenSearchImage
- Smoke v1 index: $v1Index
- Smoke v2 index: $v2Index
- Read alias: $readAlias
- Write alias: $writeAlias
- Current alias: $currentAlias
- Measurement started at: $measurementStartedAt
- Measurement finished at: $measurementFinishedAt
- Final smoke status: pass

| metric | value |
|---|---:|
| p95 event lag seconds | $($lagMetrics.p95EventLagSeconds) |
| p95 event lag threshold seconds | $LagP95ThresholdSeconds |
| max event lag seconds | $($lagMetrics.maxEventLagSeconds) |
| max event lag threshold seconds | $LagMaxThresholdSeconds |
| lag threshold result | $($lagMetrics.lagThresholdResult) |
| processed event count | $($lagMetrics.processedEventCount) |
| failed event count | $($lagMetrics.failedEventCount) |
| retry count | $($lagMetrics.retryCount) |
| pending before recovery | $($backlogRecovery.pendingEventCountBeforeRecovery) |
| pending after recovery | $($backlogRecovery.pendingEventCountAfterRecovery) |
| oldest pending age before recovery seconds | $($backlogRecovery.oldestPendingAgeSecondsBeforeRecovery) |
| oldest pending age after recovery seconds | $($backlogRecovery.oldestPendingAgeSecondsAfterRecovery) |
| fallback requirements defined | $($fallbackRequirements.fallbackRequirementDefined) |
| alias switch success | $aliasSwitchSuccess |
| rollback success | $rollbackSuccess |
| rollback duration ms | $($rollbackStopwatch.ElapsedMilliseconds) |
| previous index retained | $previousIndexRetained |
| reindex runbook documented | $($reindexRunbookResult.reindexRunbookDocumented) |

These thresholds are local smoke validation gates, not production SLA/SLO.
Lag, duration, and rollback timing values are local smoke metrics only.
This smoke result is not a benchmark, production capacity claim, or production readiness claim.
"@

    $summary | Set-Content -Encoding UTF8 (Join-Path $tempResultDir "ops-smoke-summary.md")

    Move-Item -LiteralPath $tempResultDir -Destination $resultDir -Force
    $success = $true

    Write-Host "PASS: OpenSearch lag/fallback/rollback operations smoke validation completed"
    Write-Host "Result artifacts: $resultDir"
} catch {
    if (Test-Path $tempResultDir) {
        $failureText = @"
This is a failed/partial smoke artifact directory.
It is not an official pass artifact.

Failure:
$($_.Exception.Message)
"@
        $failureText | Set-Content -Encoding UTF8 (Join-Path $tempResultDir "FAILED_PARTIAL.txt")
    }
    throw
} finally {
    Pop-Location
}
