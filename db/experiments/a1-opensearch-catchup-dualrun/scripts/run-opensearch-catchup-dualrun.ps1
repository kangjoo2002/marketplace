param(
    [string] $OpenSearchUrl = $env:OPENSEARCH_URL,
    [string] $OpenSearchImage = "opensearchproject/opensearch:2.15.0",
    [int] $TopK = $(if ($env:CATCHUP_TOP_K) { [int] $env:CATCHUP_TOP_K } else { 50 }),
    [int] $BatchSize = 20
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
$prepareSqlPath = Join-Path $experimentDir "sql\prepare-catchup-events.sql"
$validateSqlPath = Join-Path $experimentDir "sql\validate-catchup-results.sql"
$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$tempResultDir = Join-Path $experimentDir "results\$timestamp.partial"
$resultDir = Join-Path $experimentDir "results\$timestamp"

$indexName = "products_search_catchup_smoke_v1"
$readAlias = "products_search_catchup_smoke_read"
$writeAlias = "products_search_catchup_smoke_write"
$currentAlias = "products_search_catchup_smoke_current"
$smokeRun = "opensearch-catchup-dualrun"
$sourceMinId = -20002999
$sourceMaxId = -20002000
$mismatchThresholdRatio = 0

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

function Get-JsonLines {
    param([string] $Text)

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return @()
    }

    return @($Text -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object {
        $_ | ConvertFrom-Json
    })
}

function Write-JsonFile {
    param(
        [Parameter(Mandatory = $true)]
        [object] $Value,
        [Parameter(Mandatory = $true)]
        [string] $Path
    )

    $Value | ConvertTo-Json -Depth 70 | Set-Content -Encoding UTF8 $Path
}

function Wait-OpenSearchHealth {
    $lastError = $null
    for ($attempt = 1; $attempt -le 60; $attempt++) {
        try {
            return Invoke-OpenSearch -Method "GET" -Path "_cluster/health"
        }
        catch {
            $lastError = $_.Exception.Message
            Start-Sleep -Seconds 2
        }
    }

    throw "OpenSearch healthcheck did not succeed within 120 seconds. Last error: $lastError"
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

function Get-SourceDocuments {
    param(
        [long] $AfterProductId,
        [int] $Limit,
        [switch] $BaselineOnly
    )

    $baselineFilter = ""
    if ($BaselineOnly) {
        $baselineFilter = "AND p.id BETWEEN -20002004 AND -20002001"
    }

    $sql = @"
WITH next_products AS (
    SELECT p.*
    FROM products p
    WHERE p.id BETWEEN $sourceMinId AND $sourceMaxId
      AND p.id > $AfterProductId
      $baselineFilter
    ORDER BY p.id ASC
    LIMIT $Limit
),
documents AS (
    SELECT
        p.id AS product_id,
        jsonb_build_object(
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
    FROM next_products p
    LEFT JOIN product_options_moderate_skew po ON po.product_id = p.id
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
SELECT jsonb_build_object(
    'productId', product_id,
    'document', document
)::TEXT
FROM documents
ORDER BY product_id ASC;
"@

    return Get-JsonLines -Text (Invoke-PsqlText -Sql $sql -TuplesOnly)
}

function Invoke-BulkIndex {
    param([array] $Documents)

    if ($Documents.Count -eq 0) {
        return [pscustomobject]@{
            indexed = 0
            errors = $false
            response = $null
        }
    }

    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($item in $Documents) {
        $productId = [long] $item.productId
        $lines.Add((@{ index = @{ _id = "$productId" } } | ConvertTo-Json -Depth 5 -Compress))
        $lines.Add(($item.document | ConvertTo-Json -Depth 60 -Compress))
    }

    $bulkBody = ($lines -join "`n") + "`n"
    $response = Invoke-OpenSearch -Method "POST" -Path "$writeAlias/_bulk?refresh=true" -Body $bulkBody -ContentType "application/x-ndjson"

    return [pscustomobject]@{
        indexed = $Documents.Count
        errors = [bool] $response.errors
        response = $response
    }
}

function Add-CatchupEvents {
    $sql = @"
BEGIN;

UPDATE products
SET
    price = 34900,
    review_count = 120,
    updated_at = TIMESTAMP '2026-05-02 12:20:00'
WHERE id = -20002002;

INSERT INTO products (
    id,
    seller_id,
    category_id,
    brand_id,
    status,
    price,
    rating,
    review_count,
    created_at,
    updated_at
)
VALUES (
    -20002000,
    20000,
    75,
    943,
    'ACTIVE',
    25900,
    4.55,
    222,
    TIMESTAMP '2026-05-02 12:21:00',
    TIMESTAMP '2026-05-02 12:21:00'
);

INSERT INTO product_options_moderate_skew (
    id,
    product_id,
    color,
    size,
    stock_status
)
VALUES
    (-2000200001, -20002000, 'BLACK', 'S', 'IN_STOCK'),
    (-2000200002, -20002000, 'RED', 'M', 'LOW_STOCK');

UPDATE products
SET
    status = 'DELETED',
    updated_at = TIMESTAMP '2026-05-02 12:22:00'
WHERE id = -20002003;

INSERT INTO search_outbox (
    aggregate_type,
    aggregate_id,
    event_type,
    payload,
    created_at,
    updated_at
)
VALUES
    (
        'PRODUCT',
        -20002002,
        'PRODUCT_UPDATED',
        jsonb_build_object(
            'productId', -20002002,
            'eventType', 'PRODUCT_UPDATED',
            'sourceUpdatedAt', '2026-05-02T12:20:00',
            'tombstone', false,
            'smokeRun', '$smokeRun'
        ),
        now(),
        now()
    ),
    (
        'PRODUCT',
        -20002000,
        'PRODUCT_CREATED',
        jsonb_build_object(
            'productId', -20002000,
            'eventType', 'PRODUCT_CREATED',
            'sourceUpdatedAt', '2026-05-02T12:21:00',
            'tombstone', false,
            'smokeRun', '$smokeRun'
        ),
        now(),
        now()
    ),
    (
        'PRODUCT',
        -20002003,
        'PRODUCT_STATUS_CHANGED',
        jsonb_build_object(
            'productId', -20002003,
            'eventType', 'PRODUCT_STATUS_CHANGED',
            'sourceUpdatedAt', '2026-05-02T12:22:00',
            'previousStatus', 'ACTIVE',
            'newStatus', 'DELETED',
            'tombstone', false,
            'smokeRun', '$smokeRun'
        ),
        now(),
        now()
    );

COMMIT;

SELECT jsonb_build_object(
    'insertedCatchupEvents', 3,
    'updatedProductId', -20002002,
    'createdProductId', -20002000,
    'deletedProductId', -20002003
)::TEXT;
"@

    return Invoke-PsqlText -Sql $sql -TuplesOnly | ConvertFrom-Json
}

function Claim-OutboxEvents {
    param([long] $BackfillStartOutboxId)

    $sql = @"
BEGIN;
WITH claimed AS (
    SELECT id
    FROM search_outbox
    WHERE aggregate_type = 'PRODUCT'
      AND status = 'PENDING'
      AND id > $BackfillStartOutboxId
      AND payload->>'smokeRun' = '$smokeRun'
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

    return Get-JsonLines -Text (Invoke-PsqlText -Sql $sql -TuplesOnly)
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

function Invoke-CatchupReplay {
    param([long] $BackfillStartOutboxId)

    $processed = @()
    $failed = @()
    $batchCount = 0

    while ($true) {
        $events = @(Claim-OutboxEvents -BackfillStartOutboxId $BackfillStartOutboxId)
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
                        Invoke-OpenSearch -Method "DELETE" -Path "$writeAlias/_doc/${productId}?refresh=true" | Out-Null
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
                    Invoke-OpenSearch -Method "PUT" -Path "$writeAlias/_doc/${productId}?refresh=true" -Body $document | Out-Null
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

function Get-DbIdsForScenario {
    param([string] $Scenario)

    if ($Scenario -eq "C1_selective_option_filter") {
        $sql = @"
SELECT p.id::TEXT
FROM products p
WHERE p.id BETWEEN $sourceMinId AND $sourceMaxId
  AND p.status = 'ACTIVE'
  AND p.category_id = 75
  AND p.brand_id = 943
  AND EXISTS (
      SELECT 1
      FROM product_options_moderate_skew po
      WHERE po.product_id = p.id
        AND po.color = 'BLACK'
        AND po.size = 'S'
        AND po.stock_status = 'IN_STOCK'
  )
ORDER BY p.review_count DESC, p.id DESC
LIMIT $TopK;
"@
    }
    elseif ($Scenario -eq "C2_active_status_filter") {
        $sql = @"
SELECT p.id::TEXT
FROM products p
WHERE p.id BETWEEN $sourceMinId AND $sourceMaxId
  AND p.status = 'ACTIVE'
ORDER BY p.review_count DESC, p.id DESC
LIMIT $TopK;
"@
    }
    elseif ($Scenario -eq "C3_deleted_exclusion") {
        $sql = @"
SELECT p.id::TEXT
FROM products p
WHERE p.id BETWEEN $sourceMinId AND $sourceMaxId
  AND p.status = 'ACTIVE'
  AND EXISTS (
      SELECT 1
      FROM product_options_moderate_skew po
      WHERE po.product_id = p.id
        AND po.color = 'GRAY'
        AND po.size = 'M'
        AND po.stock_status = 'LOW_STOCK'
  )
ORDER BY p.review_count DESC, p.id DESC
LIMIT $TopK;
"@
    }
    else {
        throw "Unknown DB scenario $Scenario"
    }

    $text = Invoke-PsqlText -Sql $sql -TuplesOnly
    if ([string]::IsNullOrWhiteSpace($text)) {
        return @()
    }

    return @($text -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { [long] $_ })
}

function Get-SearchQueryForScenario {
    param([string] $Scenario)

    $rangeFilter = @{ range = @{ productId = @{ gte = $sourceMinId; lte = $sourceMaxId } } }
    $activeFilter = @{ term = @{ status = "ACTIVE" } }

    if ($Scenario -eq "C1_selective_option_filter") {
        $filters = @(
            $rangeFilter,
            $activeFilter,
            @{ term = @{ categoryId = 75 } },
            @{ term = @{ brandId = 943 } },
            @{
                nested = @{
                    path = "options"
                    query = @{
                        bool = @{
                            filter = @(
                                @{ term = @{ "options.color" = "BLACK" } },
                                @{ term = @{ "options.size" = "S" } },
                                @{ term = @{ "options.stockStatus" = "IN_STOCK" } }
                            )
                        }
                    }
                }
            }
        )
    }
    elseif ($Scenario -eq "C2_active_status_filter") {
        $filters = @($rangeFilter, $activeFilter)
    }
    elseif ($Scenario -eq "C3_deleted_exclusion") {
        $filters = @(
            $rangeFilter,
            $activeFilter,
            @{
                nested = @{
                    path = "options"
                    query = @{
                        bool = @{
                            filter = @(
                                @{ term = @{ "options.color" = "GRAY" } },
                                @{ term = @{ "options.size" = "M" } },
                                @{ term = @{ "options.stockStatus" = "LOW_STOCK" } }
                            )
                        }
                    }
                }
            }
        )
    }
    else {
        throw "Unknown search scenario $Scenario"
    }

    return @{
        size = $TopK
        _source = @("productId", "sourceUpdatedAt")
        sort = @(
            @{ reviewCount = @{ order = "desc" } },
            @{ productId = @{ order = "desc" } }
        )
        query = @{
            bool = @{
                filter = $filters
            }
        }
    }
}

function Get-SearchIdsForScenario {
    param([string] $Scenario)

    $query = Get-SearchQueryForScenario -Scenario $Scenario
    $response = Invoke-OpenSearch -Method "POST" -Path "$readAlias/_search" -Body $query
    return @{
        query = $query
        ids = @($response.hits.hits | ForEach-Object { [long] $_._source.productId })
        response = $response
    }
}

function Compare-TopKIds {
    param(
        [string] $Scenario,
        [long[]] $DbIds,
        [long[]] $SearchIds
    )

    $missing = @($DbIds | Where-Object { $SearchIds -notcontains $_ })
    $extra = @($SearchIds | Where-Object { $DbIds -notcontains $_ })
    $orderingMismatchPositions = @()
    $maxCount = [Math]::Max($DbIds.Count, $SearchIds.Count)

    for ($i = 0; $i -lt $maxCount; $i++) {
        $dbValue = $null
        $searchValue = $null
        if ($i -lt $DbIds.Count) { $dbValue = $DbIds[$i] }
        if ($i -lt $SearchIds.Count) { $searchValue = $SearchIds[$i] }
        if ($dbValue -ne $searchValue) {
            $orderingMismatchPositions += [pscustomobject]@{
                position = $i
                dbProductId = $dbValue
                searchProductId = $searchValue
            }
        }
    }

    return [pscustomobject]@{
        scenario = $Scenario
        dbIds = $DbIds
        searchIds = $SearchIds
        missingInSearchCount = $missing.Count
        missingInSearchProductIds = $missing
        extraInSearchCount = $extra.Count
        extraInSearchProductIds = $extra
        orderingMismatchCount = $orderingMismatchPositions.Count
        orderingMismatchPositions = $orderingMismatchPositions
        mismatchCount = $missing.Count + $extra.Count + $orderingMismatchPositions.Count
    }
}

function Get-DbUpdatedAtByProductId {
    param([long[]] $ProductIds)

    if ($ProductIds.Count -eq 0) {
        return @{}
    }

    $idList = ($ProductIds | Sort-Object -Unique) -join ","
    $sql = @"
SELECT jsonb_build_object(
    'productId', id,
    'updatedAt', to_char(updated_at, 'YYYY-MM-DD"T"HH24:MI:SS')
)::TEXT
FROM products
WHERE id IN ($idList)
ORDER BY id;
"@

    $map = @{}
    foreach ($row in @(Get-JsonLines -Text (Invoke-PsqlText -Sql $sql -TuplesOnly))) {
        $map[[string] $row.productId] = [string] $row.updatedAt
    }
    return $map
}

function Compare-StaleUpdatedAt {
    param([long[]] $ProductIds)

    $uniqueIds = @($ProductIds | Sort-Object -Unique)
    $dbUpdatedAt = Get-DbUpdatedAtByProductId -ProductIds $uniqueIds
    $stale = @()

    foreach ($productId in $uniqueIds) {
        $doc = Invoke-OpenSearch -Method "GET" -Path "$readAlias/_doc/$productId"
        $sourceUpdatedAt = [string] $doc._source.sourceUpdatedAt
        $expectedUpdatedAt = [string] $dbUpdatedAt[[string] $productId]
        if ($sourceUpdatedAt -ne $expectedUpdatedAt) {
            $stale += [pscustomobject]@{
                productId = $productId
                dbUpdatedAt = $expectedUpdatedAt
                searchSourceUpdatedAt = $sourceUpdatedAt
            }
        }
    }

    return [pscustomobject]@{
        checkedProductCount = $uniqueIds.Count
        staleByUpdatedAtCount = $stale.Count
        staleProducts = $stale
    }
}

Push-Location $repoRoot
$success = $false
try {
    Write-Host "Checking OpenSearch health at $OpenSearchUrl"
    $health = Wait-OpenSearchHealth

    Write-Host "Applying PostgreSQL catch-up smoke schemas"
    Invoke-PsqlFile -SqlPath $outboxSchemaPath | Out-Null
    Invoke-PsqlFile -SqlPath $productOptionsSchemaPath | Out-Null

    New-Item -ItemType Directory -Force -Path $tempResultDir | Out-Null

    Write-Host "Preparing PostgreSQL baseline source data"
    $prepareResult = Invoke-PsqlFile -SqlPath $prepareSqlPath -TuplesOnly | ConvertFrom-Json

    Write-Host "Resetting catch-up smoke OpenSearch index"
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

    $indexCreate = Invoke-OpenSearch -Method "PUT" -Path $indexName -BodyPath $mappingPath
    $aliasCreate = Invoke-OpenSearch -Method "POST" -Path "_aliases" -Body @{
        actions = @(
            @{ add = @{ index = $indexName; alias = $readAlias } },
            @{ add = @{ index = $indexName; alias = $writeAlias } },
            @{ add = @{ index = $indexName; alias = $currentAlias } }
        )
    }

    Write-Host "Creating backfilled baseline state in OpenSearch"
    $baselineDocs = @(Get-SourceDocuments -AfterProductId $sourceMinId -Limit 100 -BaselineOnly)
    $baselineIndexResult = Invoke-BulkIndex -Documents $baselineDocs
    if ($baselineIndexResult.errors) {
        throw "Baseline OpenSearch bulk index returned errors"
    }

    $backfillStartOutboxIdText = Invoke-PsqlText -Sql "SELECT COALESCE(MAX(id), 0)::TEXT FROM search_outbox;" -TuplesOnly
    $backfillStartOutboxId = [long] $backfillStartOutboxIdText

    Write-Host "Inserting catch-up events after outbox high-watermark $backfillStartOutboxId"
    $catchupFixture = Add-CatchupEvents

    Write-Host "Running catch-up replay"
    $replayStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $replay = Invoke-CatchupReplay -BackfillStartOutboxId $backfillStartOutboxId
    $replayStopwatch.Stop()

    $dbValidation = Invoke-PsqlFile -SqlPath $validateSqlPath -TuplesOnly | ConvertFrom-Json
    $replayedEventCount = @($replay.processed).Count
    $failedReplayEventCount = @($replay.failed).Count
    $pendingAfterReplay = [int] $dbValidation.pendingAfterReplay
    $failedAfterReplay = [int] $dbValidation.failedAfterReplay

    Write-Host "Running static DB/Search snapshot comparison"
    $snapshotCapturedAt = (Get-Date).ToString("o")
    $scenarios = @(
        "C1_selective_option_filter",
        "C2_active_status_filter",
        "C3_deleted_exclusion"
    )
    $dbQueryResults = @()
    $searchQueryResults = @()
    $comparisons = @()

    foreach ($scenario in $scenarios) {
        $dbIds = @(Get-DbIdsForScenario -Scenario $scenario)
        $searchResult = Get-SearchIdsForScenario -Scenario $scenario
        $searchIds = @($searchResult.ids)

        $dbQueryResults += [pscustomobject]@{
            scenario = $scenario
            productIds = $dbIds
        }
        $searchQueryResults += [pscustomobject]@{
            scenario = $scenario
            productIds = $searchIds
            query = $searchResult.query
        }
        $comparisons += Compare-TopKIds -Scenario $scenario -DbIds $dbIds -SearchIds $searchIds
    }

    $missingInSearchCount = [int] (($comparisons | Measure-Object -Property missingInSearchCount -Sum).Sum)
    $extraInSearchCount = [int] (($comparisons | Measure-Object -Property extraInSearchCount -Sum).Sum)
    $orderingMismatchCount = [int] (($comparisons | Measure-Object -Property orderingMismatchCount -Sum).Sum)
    $mismatchCount = [int] (($comparisons | Measure-Object -Property mismatchCount -Sum).Sum)
    $topKMismatchCount = $mismatchCount
    $totalDbResultCount = [int] (($dbQueryResults | ForEach-Object { $_.productIds.Count } | Measure-Object -Sum).Sum)
    $denominator = [Math]::Max($totalDbResultCount, 1)
    $mismatchRatio = [Math]::Round($mismatchCount / $denominator, 6)
    $sampleDiffs = @($comparisons | Where-Object { $_.mismatchCount -gt 0 })
    $sampleDiffCount = $sampleDiffs.Count

    $comparedProductIds = @($dbQueryResults | ForEach-Object { $_.productIds } | Sort-Object -Unique)
    $staleUpdatedAt = Compare-StaleUpdatedAt -ProductIds $comparedProductIds

    $staticSnapshot = [pscustomobject]@{
        dualRunMode = "static_shadow_comparison"
        snapshotCapturedAt = $snapshotCapturedAt
        comparedQueryCount = $scenarios.Count
        topK = $TopK
        mismatchThresholdRatio = $mismatchThresholdRatio
    }

    $mismatchReport = [pscustomobject]@{
        mismatchThresholdRatio = $mismatchThresholdRatio
        mismatchCount = $mismatchCount
        mismatchRatio = $mismatchRatio
        topKMismatchCount = $topKMismatchCount
        missingInSearchCount = $missingInSearchCount
        extraInSearchCount = $extraInSearchCount
        orderingMismatchCount = $orderingMismatchCount
        comparisons = $comparisons
    }

    $sampleDiffResult = [pscustomobject]@{
        sampleDiffCount = $sampleDiffCount
        sampleDiffs = $sampleDiffs
    }

    $replaySummary = [pscustomobject]@{
        backfillStartOutboxId = $backfillStartOutboxId
        catchUpReplayPredicate = "search_outbox.id > $backfillStartOutboxId"
        replayedEventCount = $replayedEventCount
        replayDurationMs = $replayStopwatch.ElapsedMilliseconds
        pendingAfterReplay = $pendingAfterReplay
        failedAfterReplay = $failedAfterReplay
        replayBatchCount = $replay.batchCount
        processed = $replay.processed
        failed = $replay.failed
    }

    $highWatermark = [pscustomobject]@{
        backfillStartOutboxId = $backfillStartOutboxId
        catchUpReplayPredicate = "search_outbox.id > $backfillStartOutboxId"
        highWatermarkSource = "fresh controlled smoke baseline before catch-up events"
    }

    if ($baselineDocs.Count -ne 4) { throw "Expected baseline document count 4, got $($baselineDocs.Count)" }
    if ($replayedEventCount -ne 3) { throw "Expected replayed event count 3, got $replayedEventCount" }
    if ($failedReplayEventCount -ne 0) { throw "Expected failed replay event count 0, got $failedReplayEventCount" }
    if ($pendingAfterReplay -ne 0) { throw "Expected pending after replay 0, got $pendingAfterReplay" }
    if ($failedAfterReplay -ne 0) { throw "Expected failed after replay 0, got $failedAfterReplay" }
    if ($mismatchCount -ne 0) { throw "Expected mismatch count 0, got $mismatchCount" }
    if ($mismatchRatio -ne 0) { throw "Expected mismatch ratio 0, got $mismatchRatio" }
    if ($missingInSearchCount -ne 0) { throw "Expected missing in search count 0, got $missingInSearchCount" }
    if ($extraInSearchCount -ne 0) { throw "Expected extra in search count 0, got $extraInSearchCount" }
    if ($orderingMismatchCount -ne 0) { throw "Expected ordering mismatch count 0, got $orderingMismatchCount" }
    if ($sampleDiffCount -ne 0) { throw "Expected sample diff count 0, got $sampleDiffCount" }
    if ($staleUpdatedAt.staleByUpdatedAtCount -ne 0) { throw "Expected stale by updated_at count 0, got $($staleUpdatedAt.staleByUpdatedAtCount)" }

    $summary = @"
# OpenSearch Catch-up Dual-run Smoke Summary

- PostgreSQL target: docker compose postgres/readpath_lab
- OpenSearch URL: $OpenSearchUrl
- OpenSearch image: $OpenSearchImage
- Smoke index: $indexName
- Read alias: $readAlias
- Write alias: $writeAlias
- Dual-run mode: static_shadow_comparison
- Final smoke status: pass

| metric | value |
|---|---:|
| backfill start outbox id | $backfillStartOutboxId |
| replayed event count | $replayedEventCount |
| replay duration ms | $($replayStopwatch.ElapsedMilliseconds) |
| pending after replay | $pendingAfterReplay |
| failed after replay | $failedAfterReplay |
| compared query count | $($scenarios.Count) |
| mismatch threshold ratio | $mismatchThresholdRatio |
| mismatch count | $mismatchCount |
| mismatch ratio | $mismatchRatio |
| top-k mismatch count | $topKMismatchCount |
| missing in search count | $missingInSearchCount |
| extra in search count | $extraInSearchCount |
| ordering mismatch count | $orderingMismatchCount |
| sample diff count | $sampleDiffCount |
| stale by updated_at count | $($staleUpdatedAt.staleByUpdatedAtCount) |

Snapshot captured at: $snapshotCapturedAt

Search remains a shadow comparison target in this smoke. No API read-path switch is implemented.
This smoke result is not a benchmark or production migration readiness claim.
"@

    Write-JsonFile -Value $highWatermark -Path (Join-Path $tempResultDir "high-watermark-result.json")
    Write-JsonFile -Value $replaySummary -Path (Join-Path $tempResultDir "replay-summary-result.json")
    Write-JsonFile -Value $staticSnapshot -Path (Join-Path $tempResultDir "static-snapshot-result.json")
    Write-JsonFile -Value $dbQueryResults -Path (Join-Path $tempResultDir "db-query-results.json")
    Write-JsonFile -Value $searchQueryResults -Path (Join-Path $tempResultDir "search-query-results.json")
    Write-JsonFile -Value $mismatchReport -Path (Join-Path $tempResultDir "mismatch-report.json")
    Write-JsonFile -Value $sampleDiffResult -Path (Join-Path $tempResultDir "sample-diff-result.json")
    Write-JsonFile -Value $staleUpdatedAt -Path (Join-Path $tempResultDir "stale-updated-at-result.json")
    $summary | Set-Content -Encoding UTF8 (Join-Path $tempResultDir "catchup-dualrun-summary.md")

    Move-Item -LiteralPath $tempResultDir -Destination $resultDir -Force
    $success = $true

    Write-Host "PASS: OpenSearch catch-up dual-run smoke validation completed"
    Write-Host "Result artifacts: $resultDir"
} finally {
    Pop-Location
    if (-not $success -and (Test-Path $tempResultDir)) {
        Remove-Item -LiteralPath $tempResultDir -Recurse -Force
    }
}
